#!/usr/bin/env python3
"""Build docs/diagrams/dxm1-pipeline.{svg,dark.svg}.

The diagram is generated rather than hand-edited so it can be kept in step with
reality. An earlier hand-authored revision drifted: it still advertised the
acceptance tally from an older run and stopped at "NPU inference", omitting the
whole on-screen DX-Stream path that the desktop lab image exists to provide.

Every coordinate is derived from the constants below; none is eyeballed.

    python3 docs/diagrams/build_dxm1_pipeline.py
    python3 -c "import cairosvg" || pip install cairosvg   # for the PNG fallback
"""
import re

W, H = 1280, 900
MARGIN = 48
ZONE_Y = 116
ZONE_W = 564
ZONE_H = H - ZONE_Y - 154          # leaves room for the footer block
HOST_X = MARGIN                    # 48
TGT_X = W - MARGIN - ZONE_W        # 668
HOST_BOX_W = 508
# The target boxes are deliberately narrower than the host ones: the rejection
# callout hangs off their right edge and must stay inside the canvas.
TGT_BOX_W = 400
BOX_H = 66
BOX_GAP = 30                       # 6 target boxes must fit inside ZONE_H
PAD_TOP = 44                       # zone top -> first box

SANS = ("Inter, 'IBM Plex Sans', 'Segoe UI', system-ui, "
        "'Liberation Sans', 'DejaVu Sans', sans-serif")
MONO = "'JetBrains Mono', 'IBM Plex Mono', 'DejaVu Sans Mono', monospace"

LIGHT = dict(page="#FFFFFF", band="#F7F9FC", band_anchor="#F1F5F9", card="#FFFFFF",
             stroke="#D3DAE6", ink="#0F172A", muted="#64748B", faint="#94A3B8",
             connector="#9AA6B8", accent="#4F46E5", accent_tint="#EEF0FE",
             danger="#DC2626")
DARK = dict(page="#0A0E1A", band="#0F1626", band_anchor="#0C1322", card="#182338",
            stroke="#4A5C82", ink="#FFFFFF", muted="#9FB0CF", faint="#6B7D9E",
            connector="#5A6B86", accent="#818CF8", accent_tint="#232A4A",
            danger="#F87171")

_ENTITY = r'#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*'


def esc(s):
    """XML-escape, preserving intentional entity references such as &#183;."""
    s = re.sub(r'&(?!(?:' + _ENTITY + r');)', '&amp;', str(s))
    return s.replace('<', '&lt;').replace('>', '&gt;')


def box_y(i):
    return ZONE_Y + PAD_TOP + i * (BOX_H + BOX_GAP)


def build(t):
    o = []
    a = o.append
    a(f'<svg viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" '
      f'font-family="{SANS}">')
    a('<defs>')
    for mid, col in (("arw", t["connector"]), ("arwA", t["accent"]),
                     ("arwDanger", t["danger"])):
        a(f'<marker id="{mid}" markerWidth="9" markerHeight="9" refX="7" refY="3" '
          f'orient="auto"><path d="M0,0 L7,3 L0,6 Z" fill="{col}"/></marker>')
    a('</defs>')
    a(f'<rect width="{W}" height="{H}" fill="{t["page"]}"/>')

    # ---- title block ----------------------------------------------------
    a(f'<text x="{MARGIN}" y="60" font-size="26" font-weight="700" '
      f'fill="{t["ink"]}">DX-M1: model to on-screen inference</text>')
    a(f'<text x="{MARGIN}" y="86" font-size="14" fill="{t["muted"]}">'
      f'hardware validated 2026-09-04 &#183; 26 acceptance checks &#183; '
      f'0 failures &#183; 1 finding</text>')
    pill_w = 187
    a(f'<rect x="{W - MARGIN - pill_w}" y="44" width="{pill_w}" height="30" rx="15" '
      f'fill="{t["accent_tint"]}"/>')
    a(f'<circle cx="{W - MARGIN - pill_w + 18}" cy="59" r="4" fill="{t["accent"]}"/>')
    a(f'<text x="{W - MARGIN - pill_w + 32}" y="63" font-size="12.5" '
      f'fill="{t["accent"]}" font-weight="600">verified target path</text>')

    # ---- zones ----------------------------------------------------------
    for x, label, anchor in ((HOST_X, "HOST &#183; x86_64", False),
                             (TGT_X, "TARGET &#183; aarch64 (Yocto build + board)", True)):
        a(f'<rect x="{x}" y="{ZONE_Y}" width="{ZONE_W}" height="{ZONE_H}" rx="12" '
          f'fill="{t["band_anchor"] if anchor else t["band"]}"/>')
        a(f'<text x="{x + ZONE_W / 2:.1f}" y="{ZONE_Y + 26}" font-size="11.5" '
          f'font-weight="700" fill="{t["faint"]}" letter-spacing="0.5" '
          f'text-anchor="middle">{label}</text>')

    def box(x, w, i, title, sub, accent=False, dashed=False, mono=True):
        y = box_y(i)
        fill = t["accent_tint"] if accent else t["card"]
        st = t["accent"] if accent else t["stroke"]
        dash = ' stroke-dasharray="5,4"' if dashed else ''
        op = ' opacity="0.6"' if dashed else ''
        a(f'<rect x="{x}" y="{y}" width="{w}" height="{BOX_H}" rx="10" fill="{fill}" '
          f'stroke="{st}" stroke-width="{1.8 if accent else 1.4}"{dash}{op}/>')
        cx = x + w / 2
        a(f'<text x="{cx:.1f}" y="{y + 28}" font-size="14.5" font-weight="600" '
          f'fill="{t["accent"] if accent else t["ink"]}" text-anchor="middle">'
          f'{esc(title)}</text>')
        a(f'<text x="{cx:.1f}" y="{y + 48}" font-size="11.5" fill="{t["muted"]}" '
          f'text-anchor="middle" font-family="{MONO if mono else SANS}">{esc(sub)}</text>')

    def vlink(x, w, i, accent=False, dashed=False):
        cx = x + w / 2
        y1, y2 = box_y(i) + BOX_H, box_y(i + 1)
        d = ' stroke-dasharray="5,4"' if dashed else ''
        a(f'<line x1="{cx:.1f}" y1="{y1}" x2="{cx:.1f}" y2="{y2 - 6}" '
          f'stroke="{t["accent"] if accent else t["connector"]}" stroke-width="1.6"{d} '
          f'marker-end="url(#{"arwA" if accent else "arw"})"/>')

    HX, TX = HOST_X + 28, TGT_X + 24

    # ---- host column: vendor workflow, not exercised here ----------------
    box(HX, HOST_BOX_W, 0, "Trained model", "PyTorch / ONNX")
    vlink(HX, HOST_BOX_W, 0, dashed=True)
    box(HX, HOST_BOX_W, 1, "DX-COM compile",
        "quantize + optimize &#8594; .dxnn", dashed=True)
    a(f'<text x="{HX + HOST_BOX_W / 2:.1f}" y="{box_y(1) + BOX_H + 26}" font-size="11.5" '
      f'fill="{t["faint"]}" text-anchor="middle">vendor tooling &#183; '
      f'NOT verified in this repo</text>')

    # ---- host -> target: only the compiled artefact crosses --------------
    mid_x = (HOST_X + ZONE_W + TGT_X) / 2
    a(f'<line x1="{mid_x:.1f}" y1="{ZONE_Y}" x2="{mid_x:.1f}" y2="{ZONE_Y + ZONE_H}" '
      f'stroke="{t["stroke"]}" stroke-width="1.2" stroke-dasharray="3,5"/>')
    a(f'<text x="{mid_x:.1f}" y="{ZONE_Y - 10}" font-size="11.5" font-weight="700" '
      f'fill="{t["faint"]}" letter-spacing="0.5" text-anchor="middle">'
      f'HOST &#8594; TARGET</text>')
    a(f'<path d="M{HOST_X + ZONE_W - 20},{box_y(1) + BOX_H / 2:.1f} '
      f'L{TX - 10},{box_y(3) + BOX_H / 2:.1f}" fill="none" stroke="{t["connector"]}" '
      f'stroke-width="1.6" marker-end="url(#arw)"/>')
    a(f'<text x="{mid_x:.1f}" y="{box_y(2) + BOX_H + 22}" font-size="11.5" '
      f'fill="{t["muted"]}" text-anchor="middle">compiled .dxnn</text>')

    # ---- target column: build-time trust, then the runtime data path -----
    box(TX, TGT_BOX_W, 0, "Kernel + dx-driver build",
        "Kbuild signs .ko &#183; persistent MODULE_SIG_KEY")
    vlink(TX, TGT_BOX_W, 0)
    box(TX, TGT_BOX_W, 1, "Boot: module load",
        "PCI modalias &#8594; dx_dma &#8594; post: dxrt_driver", accent=True)
    vlink(TX, TGT_BOX_W, 1, accent=True)
    box(TX, TGT_BOX_W, 2, "dxrtd runtime", "User=dxrt &#183; /dev/dxrt* 0660", accent=True)
    vlink(TX, TGT_BOX_W, 2, accent=True)
    box(TX, TGT_BOX_W, 3, "NPU inference",
        "Gen2 x1 &#183; ASPM off &#183; 3 cores utilized", accent=True)
    vlink(TX, TGT_BOX_W, 3, accent=True)
    box(TX, TGT_BOX_W, 4, "DX-Stream pipeline",
        "dxpreprocess &#8594; dxinfer &#8594; dxpostprocess &#8594; dxosd", accent=True)
    vlink(TX, TGT_BOX_W, 4, accent=True)
    box(TX, TGT_BOX_W, 5, "Weston &#183; HDMI", "waylandsink &#183; desktop lab image", accent=True)

    # ---- rejection callout on the module-load box ------------------------
    ry = box_y(1) + BOX_H / 2
    a(f'<text x="{TX + TGT_BOX_W + 14}" y="{ry - 14:.1f}" font-size="10.5" '
      f'fill="{t["danger"]}">unsigned .ko</text>')
    a(f'<line x1="{TX + TGT_BOX_W + 14}" y1="{ry:.1f}" x2="{TX + TGT_BOX_W + 46}" y2="{ry:.1f}" '
      f'stroke="{t["danger"]}" stroke-width="1.6" stroke-dasharray="4,3" '
      f'marker-end="url(#arwDanger)"/>')
    a(f'<circle cx="{TX + TGT_BOX_W + 58}" cy="{ry:.1f}" r="9" fill="none" '
      f'stroke="{t["danger"]}" stroke-width="1.6"/>')
    a(f'<text x="{TX + TGT_BOX_W + 58}" y="{ry + 4:.1f}" font-size="11" '
      f'fill="{t["danger"]}" text-anchor="middle">&#215;</text>')
    a(f'<text x="{TX + TGT_BOX_W + 14}" y="{ry + 26:.1f}" font-size="10.5" '
      f'fill="{t["danger"]}">&#8594; EKEYREJECTED</text>')

    # ---- footer ----------------------------------------------------------
    notes = [
        ("Solid accent = hardware-validated path: signed modules, unprivileged "
         "runtime, real NPU inference, on-screen output.", t["muted"]),
        ("Acceptance: 26 PASS / 0 FAIL / 1 FINDING (SELinux domains still "
         "permissive); dxtop showed utilization on all three NPU cores.", t["muted"]),
        ("Dashed host path = vendor DX-COM workflow not exercised here; the demo "
         "ships a precompiled YoloV5S_PPU.dxnn.", t["faint"]),
        ("Delivered to slot B by full-FIT RAUC install; see docs/DEEPX_DXM1.md for "
         "the remaining production work.", t["faint"]),
    ]
    fy = ZONE_Y + ZONE_H + 34
    for i, (text, col) in enumerate(notes):
        a(f'<text x="{MARGIN}" y="{fy + i * 19}" font-size="12" fill="{col}">'
          f'{esc(text)}</text>')

    a('</svg>')
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    import pathlib
    here = pathlib.Path(__file__).parent
    (here / "dxm1-pipeline.svg").write_text(build(LIGHT))
    (here / "dxm1-pipeline.dark.svg").write_text(build(DARK))
    print("wrote dxm1-pipeline.svg and dxm1-pipeline.dark.svg")
