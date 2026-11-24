"""Summarize completed churn runs and draw the README charts from their raw samples."""

import argparse
import csv
import json
from datetime import datetime
from pathlib import Path
from statistics import median

import matplotlib

matplotlib.use("Agg")
from matplotlib import pyplot as plt
from matplotlib.ticker import MaxNLocator


SERVERS = {"stock": "Stock ExCable", "batch4": "Four-frame ExCable", "cabby": "Cabby"}
COLORS = {"stock": "#395D94", "batch4": "#087764", "cabby": "#A44C16"}
WORKLOADS = {"even": "Evenly paced", "bursts": "Room bursts"}


def read_run(folder):
    load = json.loads((folder / "load.json").read_text())
    start = datetime.fromisoformat(load["measuring_from"])
    end = datetime.fromisoformat(load["measuring_to"])
    minutes = round((end - start).total_seconds() / 60)
    if minutes != 60 or load["duration_s"] != 3600:
        raise ValueError(f"Expected a completed one-hour run in {folder}")
    with (folder / "rss.csv").open() as f:
        samples = list(csv.DictReader(f))
    buckets = [[] for _ in range(minutes)]
    for sample in samples:
        t = datetime.fromisoformat(sample["timestamp_utc"])
        if start <= t < end:
            buckets[int((t - start).total_seconds() // 60)].append(sample)
    if not all(buckets):
        raise ValueError(f"A measured minute has no RSS samples in {folder}")
    rss = [median(int(s["server_kib"]) / 1024 for s in bucket) for bucket in buckets]
    during = [s for bucket in buckets for s in bucket]
    result = {
        "first_min_mib": rss[0], "last_min_mib": rss[-1],
        "peak_mib": max(int(s["server_kib"]) / 1024 for s in during),
        "last_5min_mib": median(int(s["server_kib"]) / 1024 for b in buckets[-5:] for s in b),
        "min30_to35_mib": median(int(s["server_kib"]) / 1024 for b in buckets[30:35] for s in b),
        "residual_mib": int(next(s for s in samples if s["phase"] == "residual")["server_kib"]) / 1024,
        "combined_last_min_mib": median(int(s["combined_kib"]) / 1024 for s in buckets[-1]),
        "delivery_p99_ms": load["delivery_latency_ms"]["p99"],
        "reconnect_p99_ms": load["reconnect_latency_ms"]["p99"],
        "schedule_p99_ms": load["schedule_lag_ms"]["p99"],
    }
    for key in ("delivered_per_s", "accepted_publications", "skipped_publications", "publish_errors",
                "expected_deliveries", "unique_deliveries", "missing_deliveries", "duplicates",
                "invalid_or_misrouted", "planned_disconnects", "unexpected_disconnects",
                "reconnects_completed", "reconnects_incomplete", "failed_connection_attempts"):
        result[key] = load[key]
    return result, rss


def rss_chart(out, traces):
    fig, axes = plt.subplots(2, 2, figsize=(9.8, 5.6), sharex=True, sharey="row")
    fig.subplots_adjust(top=.77, left=.10, right=.98, bottom=.11, hspace=.17, wspace=.12)
    fig.suptitle("Gateway memory during one hour of churn", x=.06, y=.98, ha="left", weight="bold")
    for col, (mode, title) in enumerate(WORKLOADS.items()):
        top, bottom = axes[:, col]
        top.set_title(title, loc="left", fontsize=12)
        for server, label in SERVERS.items():
            series = traces[mode, server]
            x = [i + .5 for i in range(len(series))]
            top.plot(x, series, color=COLORS[server], label=label, lw=2)
            bottom.plot(x, [v - series[0] for v in series], color=COLORS[server], lw=1.8)
        bottom.axhline(0, color="#999999", lw=.7)
        bottom.set(xlabel="Elapsed minutes", xlim=(0, 60), xticks=range(0, 61, 10))
    axes[0, 0].set_ylim(0, max(max(series) for series in traces.values()) * 1.06)
    axes[0, 0].set_ylabel("RSS (MiB)")
    axes[1, 0].set_ylabel("Change from first\nminute (MiB)")
    fig.legend(*axes[0, 0].get_legend_handles_labels(), loc="upper left", bbox_to_anchor=(.055,.93),
               frameon=False, ncol=3)
    fig.savefig(out / "rss.png", dpi=160)
    plt.close(fig)


def latency_chart(out, rows):
    fig, axes = plt.subplots(1, 2, figsize=(9.8, 3.5), sharey=True)
    fig.subplots_adjust(top=.69, bottom=.17, left=.19, right=.96, wspace=.20)
    fig.suptitle("Tail latency during churn", x=.06, y=.98, ha="left", weight="bold")
    for ax, key, title in zip(axes, ("delivery_p99_ms", "reconnect_p99_ms"),
                              ("Delivery p99", "Reconnect p99")):
        ax.set_title(title, loc="left", fontsize=12)
        for mode, offset, color, marker in (("even", .15, "#395D94", "o"), ("bursts", -.15, "#087764", "s")):
            for i, server in enumerate(SERVERS):
                value = rows[mode, server][key]
                y = 2 - i + offset
                ax.scatter(value, y, color=color, marker=marker, s=40,
                           label=WORKLOADS[mode] if i == 0 else None)
                ax.annotate(f"{value:.3f}", (value, y), xytext=(7, 0), textcoords="offset points",
                            va="center", fontsize=9, color=color)
        lo, hi = ax.get_xlim()
        ax.set_xlim(lo - .05 * (hi-lo), hi + .27 * (hi-lo))
        ax.set_ylim(-.45, 2.45)
        ax.xaxis.set_major_locator(MaxNLocator(4))
        ax.set_xlabel("Milliseconds")
        ax.grid(False)
        ax.grid(axis="x", alpha=.18)
    axes[0].set_yticks([2, 1, 0], list(SERVERS.values()))
    fig.legend(*axes[0].get_legend_handles_labels(), loc="upper left", bbox_to_anchor=(.055,.90),
               frameon=False, ncol=2)
    fig.savefig(out / "latency.png", dpi=160)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path, help="Report directory containing raw/<workload>/<server>")
    out = parser.parse_args().folder
    rows, traces = {}, {}
    for mode in WORKLOADS:
        for server in SERVERS:
            row, traces[mode, server] = read_run(out / "raw" / mode / server)
            rows[mode, server] = {"workload": mode, "server": server, **row}
    with (out / "summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, next(iter(rows.values())), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows.values())
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False, "axes.grid": True, "grid.alpha": .18,
                         "axes.axisbelow": True, "figure.titlesize": 18, "figure.facecolor": "white"})
    rss_chart(out, traces)
    latency_chart(out, rows)


if __name__ == "__main__":
    main()
