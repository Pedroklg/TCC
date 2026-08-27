"""Calibração do ponto de saturação (piloto, anterior à campanha definitiva).

Lê results/<alvo>/<ts>/calibration-rep01-raw.json e reconstrói, por patamar de taxa
de chegada, a vazão útil, a taxa de erro e o p95. Daí saem o teto de cada arquitetura
e a taxa de pico a usar no cenário de estresse.

A taxa oferecida vem do CRONOGRAMA do cenário, não dos dados: o k6 contabiliza uma
iteração quando ela termina, e sob saturação as iterações abortam cedo, de modo que
estimá-la pelo que foi concluído devolve valores acima da carga realmente oferecida.
Os parâmetros abaixo precisam espelhar os de scenario-calibration.js na execução lida.

Como rodar: ver analysis/README.md.
"""
import json, glob, gzip, os, sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

LABEL = {"mono": "Monolito", "micro": "Microsserviços",
         "serverless-cold": "Serverless (sem otim.)", "serverless-snap": "Serverless (SnapStart)"}
COLOR = {"mono": "tab:blue", "micro": "tab:orange",
         "serverless-cold": "tab:green", "serverless-snap": "tab:purple"}
# Traço e marcador distintos por série: a monografia é impressa, e a cor sozinha
# não separa as curvas em escala de cinza.
MARK = {"mono": "o", "micro": "s", "serverless-cold": "^", "serverless-snap": "D"}
DASH = {"mono": "-", "micro": "--", "serverless-cold": "-.", "serverless-snap": ":"}
ORDER = ["mono", "micro", "serverless-cold", "serverless-snap"]

plt.rcParams.update({"font.size": 12, "axes.titlesize": 12, "axes.labelsize": 12,
                     "legend.fontsize": 10, "xtick.labelsize": 11, "ytick.labelsize": 11})

# Cronograma do cenário (espelha os defaults de scenario-calibration.js).
START = float(os.environ.get("START_RATE", "10"))
MAXRATE = float(os.environ.get("MAX_RATE", "1000"))
STEPS = int(os.environ.get("STEPS", "12"))
RISE_S = float(os.environ.get("STEP_RISE_S", "10"))
HOLD_S = float(os.environ.get("STEP_HOLD_S", "40"))

BUCKET_S = int(os.environ.get("CALIB_BUCKET_S", "5"))
DROP_LEVEL = float(os.environ.get("CALIB_DROP_LEVEL", "0.10"))
PLATEAU = 0.95    # fração da vazão útil máxima que define o joelho
ERR_LEVEL = 5.0   # taxa de erro (%) cujo cruzamento é reportado

WANTED = {"http_reqs", "http_req_failed", "http_req_duration", "iterations", "dropped_iterations"}


def schedule():
    """Patamares (rate, t_inicio, t_fim) das fases de sustentação, em segundos."""
    out, t = [], 0.0
    for i in range(1, STEPS + 1):
        target = round(START * (MAXRATE / START) ** (i / STEPS))
        t += RISE_S                      # subida: transitório, descartado
        out.append((float(target), t, t + HOLD_S))
        t += HOLD_S
    return out


def _open(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, encoding="utf-8")


def load_run(path):
    """Agrega os Points do k6 em janelas de BUCKET_S segundos desde o início."""
    rows, t0 = {}, None
    with _open(path) as fh:
        for line in fh:
            if '"Point"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            m = o.get("metric")
            if o.get("type") != "Point" or m not in WANTED:
                continue
            d = o["data"]
            ts = pd.Timestamp(d["time"]).value / 1e9
            if t0 is None or ts < t0:
                t0 = ts
            rows.setdefault(m, []).append((ts, float(d["value"])))
    if not rows or t0 is None:
        return None

    out = {}
    for m, pts in rows.items():
        a = np.asarray(pts)
        b = ((a[:, 0] - t0) // BUCKET_S).astype(int)
        s = pd.Series(a[:, 1])
        if m == "http_req_duration":
            out["p95_ms"] = s.groupby(b).quantile(0.95)
        elif m == "http_req_failed":
            out["failed"] = s.groupby(b).sum()
            out["total"] = s.groupby(b).size()
        else:
            out[m] = s.groupby(b).sum()

    df = pd.DataFrame(out).fillna(0.0)
    df["t_mid"] = (df.index.to_numpy() + 0.5) * BUCKET_S
    df["req_s"] = df.get("http_reqs", 0) / BUCKET_S
    # Vazão ÚTIL: requisição que falhou não é trabalho entregue, e contá-la faria um
    # sistema em colapso, que responde erro rapidamente, parecer ter o maior teto.
    df["ok_req_s"] = (df["total"] - df["failed"]) / BUCKET_S
    df["iter_s"] = df.get("iterations", 0) / BUCKET_S
    df["dropped_s"] = df.get("dropped_iterations", 0) / BUCKET_S
    df["error_pct"] = 100.0 * df["failed"] / df["total"].replace(0, np.nan)
    df["drop_frac"] = df["dropped_s"] / (df["iter_s"] + df["dropped_s"]).replace(0, np.nan)
    return df


def to_levels(df):
    """Casa cada janela com o patamar do cronograma; descarta as fases de subida."""
    recs = []
    for rate, ini, fim in schedule():
        w = df[(df.t_mid >= ini) & (df.t_mid < fim)]
        if len(w) < 2:
            continue
        recs.append({
            "offered_iter_s": rate,
            "ok_req_s": w.ok_req_s.median(),
            "req_s": w.req_s.median(),
            "iter_s": w.iter_s.median(),
            "error_pct": w.error_pct.median(),
            "p95_ms": w.p95_ms.median(),
            "drop_frac": w.drop_frac.fillna(0).median(),
            "janelas": len(w),
        })
    return pd.DataFrame(recs)


def saturation(g):
    """Joelho: menor taxa oferecida que já entrega PLATEAU da vazão útil máxima."""
    if g.empty:
        return {}
    peak = g.ok_req_s.max()
    knee_rows = g[g.ok_req_s >= PLATEAU * peak]
    knee = knee_rows.offered_iter_s.min()
    at_knee = g[g.offered_iter_s == knee].iloc[0]
    # A busca do cruzamento de erro começa no joelho: antes dele, no serverless, o
    # que aparece é cold start do primeiro patamar, não degradação por carga.
    after = g[g.offered_iter_s >= knee]
    over = after[after.error_pct >= ERR_LEVEL]
    drops = after[after.drop_frac >= DROP_LEVEL]
    return {
        "teto_ok_req_s": round(peak, 1),
        "saturacao_iter_s": round(knee, 1),
        "req_por_iter_no_joelho": round(at_knee.req_s / at_knee.iter_s, 2) if at_knee.iter_s else None,
        "erro_no_joelho_pct": round(at_knee.error_pct, 2),
        "p95_no_joelho_ms": round(at_knee.p95_ms, 1),
        "erro5pct_iter_s": round(over.offered_iter_s.min(), 1) if not over.empty else None,
        "descarte10pct_iter_s": round(drops.offered_iter_s.min(), 1) if not drops.empty else None,
    }


def figure(curves, sm):
    # Dois painéis empilhados sobre o mesmo eixo x. Vazão e taxa de erro têm unidades
    # e escalas distintas: num eixo y secundário, a escolha das escalas sugeriria
    # qualquer relação desejada entre as duas curvas.
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    allg = pd.concat(curves.values())
    lo, hi = allg.offered_iter_s.min(), allg.offered_iter_s.max()
    ymax = allg.ok_req_s.max() * 1.15

    for t, g in curves.items():
        kw = dict(color=COLOR[t], marker=MARK[t], ls=DASH[t], lw=2, ms=6, zorder=3)
        ax1.plot(g.offered_iter_s, g.ok_req_s, label=LABEL[t], **kw)
        ax2.plot(g.offered_iter_s, g.error_pct, **kw)
        knee = sm.loc[t, "saturacao_iter_s"] if t in sm.index else None
        if knee is not None and not pd.isna(knee):
            y = g.loc[(g.offered_iter_s - knee).abs().idxmin(), "ok_req_s"]
            ax1.plot([knee], [y], marker="*", ms=16, color=COLOR[t],
                     mec="white", mew=1.2, ls="none", zorder=4)

    ax1.set_xscale("log")
    ax1.set_xlim(lo, hi)
    ax1.set_ylim(0, ymax)
    ax1.set_ylabel("Vazão útil (req/s, exclui erros)")
    ax1.grid(True, alpha=0.25, lw=0.6)
    ax1.legend(frameon=False, loc="upper left")
    ax1.set_title("Saturação por arquitetura (estrela: ponto de saturação)")

    ax2.axhline(ERR_LEVEL, color="0.75", lw=1, ls=(0, (2, 3)), zorder=1)
    ax2.set_ylim(-3, 103)
    ax2.set_ylabel("Erro (%)")
    ax2.set_xlabel("Taxa de chegada oferecida (iterações/s, escala log)")
    ax2.grid(True, alpha=0.25, lw=0.6)

    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "calibration.png"), dpi=150)
    plt.close(fig)


def main():
    curves, summary = {}, []
    for target in ORDER:
        paths = sorted(glob.glob(os.path.join(RESULTS, target, "*", "calibration-rep01-raw.json*")))
        if not paths:
            continue
        if len(paths) > 1:
            print(f"aviso: {target} tem {len(paths)} calibrações; usando a mais recente")
        df = load_run(paths[-1])
        if df is None:
            continue
        g = to_levels(df)
        if g.empty:
            continue
        curves[target] = g
        s = saturation(g)
        s["alvo"] = target
        summary.append(s)

    if not curves:
        sys.exit(f"Nenhum calibration-rep01-raw.json em {RESULTS}/<alvo>/<ts>/")

    long = pd.concat([g.assign(alvo=t) for t, g in curves.items()], ignore_index=True)
    long.to_csv(os.path.join(TAB, "calibration_curve.csv"), index=False)
    sm = pd.DataFrame(summary).set_index("alvo").reindex([t for t in ORDER if t in curves])
    sm.to_csv(os.path.join(TAB, "calibration_summary.csv"))

    figure(curves, sm)

    print("\n=== Calibração: teto por arquitetura (vazão ÚTIL, erros excluídos) ===")
    print(sm.to_string())
    fraco = sm["saturacao_iter_s"].min()
    forte = sm["saturacao_iter_s"].max()
    print(f"\nMenor ponto de saturação: {fraco:.0f} iter/s   |   maior: {forte:.0f} iter/s"
          f"   (razão {forte / fraco:.1f}x)")
    print(f"PEAK_RATE que ultrapassa a saturação de TODOS os braços: {1.5 * forte:.0f} iter/s")
    print(f"PEAK_RATE que ultrapassa a do braço mais fraco em 1,5x:  {1.5 * fraco:.0f} iter/s")
    print("\nQuanto maior a razão entre os tetos, menos uma taxa única serve aos dois fins.")
    print(f"\nFigura em {FIG}/calibration.png; tabelas em {TAB}/")


if __name__ == "__main__":
    main()
