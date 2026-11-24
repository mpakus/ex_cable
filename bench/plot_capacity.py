"""Plot three-way capacity results from bench/run.py's ingress and steady trial directories."""

import argparse
import json
from pathlib import Path
from statistics import median

import matplotlib

matplotlib.use("Agg")
from matplotlib import pyplot as plt
from matplotlib.ticker import MaxNLocator, StrMethodFormatter


SERVERS = {"excable": "ExCable", "cabby": "Cabby", "actioncable": "Rails Action Cable"}
COLORS = ["#147968", "#39649a", "#a7512a"]


def plot(raw, output):
    panels = [
        ("ingress/128", "accepted_http_per_s", "HTTP ingress", "Thousand accepted POSTs/s", 1000),
        ("steady/8000", "delivered_per_s", "WebSocket fan-out", "Thousand deliveries/s", 1000),
        ("steady/200", "delivery_latency_ms", "Matched-load latency", "Delivery p99 in ms", 1),
    ]
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.1), sharey=True)
    fig.subplots_adjust(left=.135, right=.98, bottom=.19, top=.72, wspace=.24)
    fig.suptitle("Action Cable server comparison", x=.03, y=.98, ha="left", weight="bold", fontsize=17)
    fig.text(.03, .81, "Median of three runs per server. Whiskers span the observed range.", fontsize=10)

    for ax, (prefix, key, title, unit, divisor) in zip(axes, panels):
        for y, (server, color) in enumerate(zip(SERVERS, COLORS)):
            values = []
            for trial in range(1, 4):
                run = json.loads((raw / f"{prefix}-{trial}-{server}" / "load.json").read_text())
                value = run[key]["p99"] if key == "delivery_latency_ms" else run[key]
                values.append(value / divisor)
            middle = median(values)
            ax.barh(y, middle, height=.44, color=color)
            ax.errorbar(middle, y, xerr=[[middle - min(values)], [max(values) - middle]],
                        fmt="none", ecolor="#1b2531", capsize=4)
            ax.annotate(f"{middle:.2f}" if divisor == 1 else f"{middle:.1f}",
                        (max(values), y), xytext=(5, 0), textcoords="offset points",
                        va="center", fontsize=9)
        ax.set_title(title, loc="left", fontsize=12, weight="bold")
        ax.set_xlabel(unit, fontsize=9)
        ax.set_xlim(0, ax.get_xlim()[1] * 1.25)
        ax.xaxis.set_major_locator(MaxNLocator(4))
        ax.xaxis.set_major_formatter(StrMethodFormatter("{x:g}"))
        ax.set_axisbelow(True)
        ax.grid(axis="x", alpha=.18)
        ax.tick_params(axis="both", length=0, labelsize=9)
        ax.spines[["top", "right", "left"]].set_visible(False)
    axes[0].set_yticks(range(3), list(SERVERS.values()))
    axes[0].invert_yaxis()
    fig.savefig(output, dpi=160, facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    plot(args.raw, args.output)
