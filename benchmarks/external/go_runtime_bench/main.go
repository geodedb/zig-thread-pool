package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	floodTaskCount      = 1_000_000
	contendedTaskCount  = 100_000
	contendedSubmitters = 8
)

type sample struct {
	ElapsedNS uint64  `json:"elapsed_ns"`
	OpsPerSec float64 `json:"ops_per_sec"`
}

type scenarioRow struct {
	ScenarioName    string   `json:"scenario_name"`
	TaskCount       int      `json:"task_count"`
	SubmitterCount  int      `json:"submitter_count"`
	WorkerCount     int      `json:"worker_count"`
	MedianElapsedNS uint64   `json:"median_elapsed_ns"`
	MedianOpsPerSec float64  `json:"median_ops_per_sec"`
	StddevOpsPerSec float64  `json:"stddev_ops_per_sec"`
	SampleCount     int      `json:"sample_count"`
	WarmupDiscarded int      `json:"warmup_discarded"`
	Samples         []sample `json:"samples"`
}

type runtimeDocument struct {
	RuntimeName      string        `json:"runtime_name"`
	RuntimeVersion   string        `json:"runtime_version"`
	SourceCommit     string        `json:"source_commit"`
	GeneratedAtUnixS int64         `json:"generated_at_unix_s"`
	HostOS           string        `json:"host_os"`
	HostArch         string        `json:"host_arch"`
	Rows             []scenarioRow `json:"rows"`
}

func main() {
	var outputPath string
	var runtimeVersion string
	var sourceCommit string
	var samples int
	var warmupDiscard int

	flag.StringVar(&outputPath, "output", "", "write JSON to this file instead of stdout")
	flag.StringVar(&runtimeVersion, "runtime-version", runtime.Version(), "runtime version label")
	flag.StringVar(&sourceCommit, "source-commit", "unknown", "source commit label")
	flag.IntVar(&samples, "samples", 7, "number of total runs to execute")
	flag.IntVar(&warmupDiscard, "warmup-discard", 1, "number of initial runs to discard")
	flag.Parse()

	if warmupDiscard >= samples {
		fmt.Fprintln(os.Stderr, "warmup-discard must be smaller than samples")
		os.Exit(2)
	}

	workerCount := runtime.NumCPU()
	rows := []scenarioRow{
		mustMeasureScenario("flood_1m", floodTaskCount, 1, workerCount, samples, warmupDiscard, runFloodSample),
		mustMeasureScenario("contended_spawn_8x", contendedTaskCount, contendedSubmitters, workerCount, samples, warmupDiscard, runContendedSample),
	}

	document := runtimeDocument{
		RuntimeName:      "go",
		RuntimeVersion:   runtimeVersion,
		SourceCommit:     sourceCommit,
		GeneratedAtUnixS: time.Now().Unix(),
		HostOS:           runtime.GOOS,
		HostArch:         runtime.GOARCH,
		Rows:             rows,
	}

	var (
		writer *os.File
		err    error
	)
	if outputPath != "" {
		writer, err = os.Create(outputPath)
	} else {
		writer = os.Stdout
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if outputPath != "" {
		defer writer.Close()
	}

	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(document); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func mustMeasureScenario(
	scenarioName string,
	taskCount int,
	submitterCount int,
	workerCount int,
	runCount int,
	warmupDiscard int,
	runOnce func(int) uint64,
) scenarioRow {
	allSamples := make([]sample, 0, runCount)
	for i := 0; i < runCount; i++ {
		elapsedNS := runOnce(workerCount)
		opsPerSec := float64(taskCount) / (float64(elapsedNS) / 1_000_000_000.0)
		allSamples = append(allSamples, sample{
			ElapsedNS: elapsedNS,
			OpsPerSec: opsPerSec,
		})
	}

	retained := append([]sample(nil), allSamples[warmupDiscard:]...)
	sort.Slice(retained, func(i, j int) bool {
		return retained[i].OpsPerSec < retained[j].OpsPerSec
	})

	median := retained[len(retained)/2]
	stddevOpsPerSec := stddevFromMedian(retained, median.OpsPerSec)

	fmt.Fprintf(
		os.Stderr,
		"go %s median_ops_per_sec=%.0f stddev_ops_per_sec=%.0f workers=%d\n",
		scenarioName,
		median.OpsPerSec,
		stddevOpsPerSec,
		workerCount,
	)

	return scenarioRow{
		ScenarioName:    scenarioName,
		TaskCount:       taskCount,
		SubmitterCount:  submitterCount,
		WorkerCount:     workerCount,
		MedianElapsedNS: median.ElapsedNS,
		MedianOpsPerSec: median.OpsPerSec,
		StddevOpsPerSec: stddevOpsPerSec,
		SampleCount:     len(retained),
		WarmupDiscarded: warmupDiscard,
		Samples:         retained,
	}
}

func runFloodSample(workerCount int) uint64 {
	runtime.GOMAXPROCS(workerCount)

	var marker atomic.Uint64
	var wait sync.WaitGroup
	wait.Add(floodTaskCount)
	start := time.Now()

	for i := 0; i < floodTaskCount; i++ {
		go func() {
			marker.Add(1)
			wait.Done()
		}()
	}

	wait.Wait()
	return uint64(time.Since(start).Nanoseconds())
}

func runContendedSample(workerCount int) uint64 {
	runtime.GOMAXPROCS(workerCount)

	perSubmitter := contendedTaskCount / contendedSubmitters
	var marker atomic.Uint64
	var taskWait sync.WaitGroup
	var submitterWait sync.WaitGroup
	taskWait.Add(contendedTaskCount)
	submitterWait.Add(contendedSubmitters)

	start := time.Now()
	for i := 0; i < contendedSubmitters; i++ {
		go func() {
			defer submitterWait.Done()
			for j := 0; j < perSubmitter; j++ {
				go func() {
					marker.Add(1)
					taskWait.Done()
				}()
			}
		}()
	}

	submitterWait.Wait()
	taskWait.Wait()
	return uint64(time.Since(start).Nanoseconds())
}

func stddevFromMedian(samples []sample, medianOpsPerSec float64) float64 {
	var sumSq float64
	for _, sample := range samples {
		delta := sample.OpsPerSec - medianOpsPerSec
		sumSq += delta * delta
	}
	return math.Sqrt(sumSq / float64(len(samples)))
}
