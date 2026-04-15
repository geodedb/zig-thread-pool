use std::env;
use std::fs::File;
use std::io::{self, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use serde::Serialize;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::Notify;

const FLOOD_TASK_COUNT: usize = 1_000_000;
const CONTENDED_TASK_COUNT: usize = 100_000;
const CONTENDED_SUBMITTERS: usize = 8;

#[derive(Clone)]
struct Args {
    output_path: Option<String>,
    runtime_version: String,
    source_commit: Option<String>,
    samples: usize,
    warmup_discard: usize,
}

#[derive(Clone, Copy, Serialize)]
struct Sample {
    elapsed_ns: u64,
    ops_per_sec: f64,
}

#[derive(Serialize)]
struct ScenarioRow {
    scenario_name: &'static str,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    median_elapsed_ns: u64,
    median_ops_per_sec: f64,
    stddev_ops_per_sec: f64,
    sample_count: usize,
    warmup_discarded: usize,
    samples: Vec<Sample>,
}

#[derive(Serialize)]
struct RuntimeDocument {
    runtime_name: &'static str,
    runtime_version: String,
    source_commit: String,
    generated_at_unix_s: i64,
    host_os: &'static str,
    host_arch: &'static str,
    rows: Vec<ScenarioRow>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = parse_args()?;
    if args.warmup_discard >= args.samples {
        return Err("warmup-discard must be smaller than samples".into());
    }

    let worker_count = thread::available_parallelism()
        .map(|value| value.get())
        .unwrap_or(1);
    let source_commit = args
        .source_commit
        .clone()
        .unwrap_or_else(|| "unknown".to_string());

    let rows = vec![
        measure_scenario(
            "flood_1m",
            FLOOD_TASK_COUNT,
            1,
            worker_count,
            args.samples,
            args.warmup_discard,
            run_flood_sample,
        )?,
        measure_scenario(
            "contended_spawn_8x",
            CONTENDED_TASK_COUNT,
            CONTENDED_SUBMITTERS,
            worker_count,
            args.samples,
            args.warmup_discard,
            run_contended_sample,
        )?,
    ];

    let document = RuntimeDocument {
        runtime_name: "tokio",
        runtime_version: args.runtime_version,
        source_commit,
        generated_at_unix_s: unix_timestamp_now()?,
        host_os: env::consts::OS,
        host_arch: env::consts::ARCH,
        rows,
    };

    if let Some(path) = args.output_path {
        let file = File::create(path)?;
        serde_json::to_writer_pretty(file, &document)?;
    } else {
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        serde_json::to_writer_pretty(&mut handle, &document)?;
        handle.write_all(b"\n")?;
    }

    Ok(())
}

fn parse_args() -> Result<Args, Box<dyn std::error::Error>> {
    let mut parsed = Args {
        output_path: None,
        runtime_version: "unknown".to_string(),
        source_commit: None,
        samples: 7,
        warmup_discard: 1,
    };

    let mut iter = env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--output" => parsed.output_path = Some(next_value(&mut iter, "--output")?),
            "--runtime-version" => {
                parsed.runtime_version = next_value(&mut iter, "--runtime-version")?
            }
            "--source-commit" => {
                parsed.source_commit = Some(next_value(&mut iter, "--source-commit")?)
            }
            "--samples" => parsed.samples = next_value(&mut iter, "--samples")?.parse()?,
            "--warmup-discard" => {
                parsed.warmup_discard = next_value(&mut iter, "--warmup-discard")?.parse()?
            }
            _ => return Err(format!("unrecognized argument: {arg}").into()),
        }
    }

    Ok(parsed)
}

fn next_value(
    iter: &mut impl Iterator<Item = String>,
    flag: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    iter.next()
        .ok_or_else(|| format!("missing value for {flag}").into())
}

fn measure_scenario(
    scenario_name: &'static str,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    run_count: usize,
    warmup_discard: usize,
    run_once: fn(usize) -> Result<u64, Box<dyn std::error::Error>>,
) -> Result<ScenarioRow, Box<dyn std::error::Error>> {
    let mut samples = Vec::with_capacity(run_count);
    for _ in 0..run_count {
        let elapsed_ns = run_once(worker_count)?;
        let ops_per_sec = task_count as f64 / (elapsed_ns as f64 / 1_000_000_000.0);
        samples.push(Sample {
            elapsed_ns,
            ops_per_sec,
        });
    }

    let mut retained = samples.split_off(warmup_discard);
    retained.sort_by(|lhs, rhs| lhs.ops_per_sec.total_cmp(&rhs.ops_per_sec));

    let median = retained[retained.len() / 2];
    let stddev_ops_per_sec = stddev_from_median(&retained, median.ops_per_sec);

    eprintln!(
        "tokio {scenario_name} median_ops_per_sec={:.0} stddev_ops_per_sec={:.0} workers={worker_count}",
        median.ops_per_sec, stddev_ops_per_sec
    );

    Ok(ScenarioRow {
        scenario_name,
        task_count,
        submitter_count,
        worker_count,
        median_elapsed_ns: median.elapsed_ns,
        median_ops_per_sec: median.ops_per_sec,
        stddev_ops_per_sec,
        sample_count: retained.len(),
        warmup_discarded: warmup_discard,
        samples: retained,
    })
}

fn run_flood_sample(worker_count: usize) -> Result<u64, Box<dyn std::error::Error>> {
    let runtime = runtime(worker_count)?;
    let notify = Arc::new(Notify::new());
    let completed = Arc::new(AtomicUsize::new(0));
    let handle = runtime.handle().clone();
    let start = Instant::now();

    for _ in 0..FLOOD_TASK_COUNT {
        let notify = notify.clone();
        let completed = completed.clone();
        handle.spawn(async move {
            if completed.fetch_add(1, Ordering::Relaxed) + 1 == FLOOD_TASK_COUNT {
                notify.notify_one();
            }
        });
    }

    wait_for_completion(&runtime, &notify, &completed, FLOOD_TASK_COUNT);
    Ok(start.elapsed().as_nanos() as u64)
}

fn run_contended_sample(worker_count: usize) -> Result<u64, Box<dyn std::error::Error>> {
    let runtime = runtime(worker_count)?;
    let notify = Arc::new(Notify::new());
    let completed = Arc::new(AtomicUsize::new(0));
    let handle = runtime.handle().clone();
    let per_submitter = CONTENDED_TASK_COUNT / CONTENDED_SUBMITTERS;
    let start = Instant::now();

    let mut submitters = Vec::with_capacity(CONTENDED_SUBMITTERS);
    for _ in 0..CONTENDED_SUBMITTERS {
        let handle = handle.clone();
        let notify = notify.clone();
        let completed = completed.clone();
        submitters.push(thread::spawn(move || {
            for _ in 0..per_submitter {
                let notify = notify.clone();
                let completed = completed.clone();
                handle.spawn(async move {
                    if completed.fetch_add(1, Ordering::Relaxed) + 1 == CONTENDED_TASK_COUNT {
                        notify.notify_one();
                    }
                });
            }
        }));
    }

    for submitter in submitters {
        submitter.join().map_err(|_| "submitter thread panicked")?;
    }

    wait_for_completion(&runtime, &notify, &completed, CONTENDED_TASK_COUNT);
    Ok(start.elapsed().as_nanos() as u64)
}

fn runtime(worker_count: usize) -> Result<Runtime, Box<dyn std::error::Error>> {
    Ok(Builder::new_multi_thread()
        .worker_threads(worker_count)
        .enable_all()
        .build()?)
}

fn wait_for_completion(
    runtime: &Runtime,
    notify: &Arc<Notify>,
    completed: &Arc<AtomicUsize>,
    target: usize,
) {
    runtime.block_on(async {
        if completed.load(Ordering::Relaxed) < target {
            notify.notified().await;
        }
    });
}

fn stddev_from_median(samples: &[Sample], median_ops_per_sec: f64) -> f64 {
    let sum_sq = samples
        .iter()
        .map(|sample| {
            let delta = sample.ops_per_sec - median_ops_per_sec;
            delta * delta
        })
        .sum::<f64>();
    (sum_sq / samples.len() as f64).sqrt()
}

fn unix_timestamp_now() -> Result<i64, Box<dyn std::error::Error>> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64)
}
