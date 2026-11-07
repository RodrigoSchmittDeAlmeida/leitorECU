"""Gerador de Laudos Técnicos de Diagnóstico Automotivo (PDF / HTML).

Exporta laudos profissionais com cabeçalho de oficina, identificação da ECU,
leitura de DTCs, monitores de prontidão I/M, freeze frame e teste elétrico.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional
from PyQt6.QtGui import QTextDocument
from PyQt6.QtWidgets import QApplication


def generate_html_report(
    ecu_meta: Dict[str, Any],
    dtcs: List[tuple[str, str]],
    mil_status: str,
    readiness: Optional[Any] = None,
    freeze_frame: Optional[Any] = None,
    card_peaks: Optional[Dict[str, tuple[Optional[float], Optional[float]]]] = None,
    battery_test: str = "Tensão estável dentro dos padrões operacionais",
) -> str:
    """Gera um laudo de diagnóstico veicular em HTML pronto para impressão ou PDF."""
    now_str = datetime.now().strftime("%d/%m/%Y às %H:%M:%S")

    display_title = ecu_meta.get("display_title", "Central Não Identificada")
    manufacturer = ecu_meta.get("manufacturer", "Fabricante Convencional")
    protocol = ecu_meta.get("protocol", "OBD-II Universal")
    vin = ecu_meta.get("vin") or "Não informado / Bloqueado"

    # Tabela de DTCs
    if dtcs:
        dtc_rows = "".join(
            f"<tr><td style='padding:6px; font-weight:bold; color:#d32f2f;'>{code}</td>"
            f"<td style='padding:6px;'>{desc}</td></tr>"
            for code, desc in dtcs
        )
    else:
        dtc_rows = "<tr><td colspan='2' style='padding:8px; color:#2e7d32; font-weight:bold;'>Nenhum código de falha gravado na memória da ECU (DTC = 0).</td></tr>"

    # Monitores de Prontidão
    readiness_rows = ""
    if readiness and hasattr(readiness, "monitors"):
        for m in readiness.monitors:
            if not m.supported:
                badge = "<span style='color:#757575; font-size:9pt;'>NÃO SUPORTADO</span>"
            elif m.completed:
                badge = "<span style='color:#2e7d32; font-weight:bold; font-size:9pt;'>✔ CONCLUÍDO (OK)</span>"
            else:
                badge = "<span style='color:#e65100; font-weight:bold; font-size:9pt;'>✖ INCOMPLETO</span>"
            readiness_rows += f"<tr><td style='padding:5px;'>{m.name}</td><td style='padding:5px; text-align:right;'>{badge}</td></tr>"

    # Freeze Frame
    ff_content = ""
    if freeze_frame and getattr(freeze_frame, "params", None):
        ff_rows = "".join(
            f"<tr><td style='padding:5px;'>{p_name}</td><td style='padding:5px; font-weight:bold; text-align:right;'>{val:.1f} {unit}</td></tr>"
            for p_name, (val, unit) in freeze_frame.params.items()
        )
        ff_content = f"""
        <div style="margin-top:15px;">
            <h3 style="color:#0288d1; border-bottom:1px solid #b3e5fc; padding-bottom:4px; font-size:12pt;">Dados Congelados da Falha (Freeze Frame — Modo 02: DTC {freeze_frame.dtc})</h3>
            <table style="width:100%; border-collapse:collapse; font-size:10pt;">{ff_rows}</table>
        </div>
        """

    # Resumo de Picos
    peaks_rows = ""
    if card_peaks:
        for k, (p_min, p_max) in card_peaks.items():
            if p_min is not None and p_max is not None:
                peaks_rows += f"<tr><td style='padding:4px;'>{k.upper()}</td><td style='padding:4px;'>{p_min:.1f}</td><td style='padding:4px;'>{p_max:.1f}</td></tr>"

    html = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <style>
            body {{ font-family: 'Segoe UI', Helvetica, Arial, sans-serif; margin: 25px; color: #212121; }}
            .header {{ border-bottom: 2px solid #1565c0; padding-bottom: 10px; margin-bottom: 20px; }}
            .title {{ font-size: 18pt; font-weight: 800; color: #1565c0; margin: 0; }}
            .subtitle {{ font-size: 10pt; color: #616161; margin: 3px 0 0 0; }}
            .box {{ background: #f5f7fa; border: 1px solid #cfd8dc; border-radius: 4px; padding: 12px; margin-bottom: 15px; }}
            h3 {{ margin: 0 0 8px 0; font-size: 12pt; }}
            table {{ width: 100%; border-collapse: collapse; }}
            th {{ text-align: left; background: #eceff1; padding: 6px; font-size: 9pt; color: #37474f; }}
            tr:nth-child(even) {{ background: #fafafa; }}
            .footer {{ margin-top: 30px; border-top: 1px solid #e0e0e0; padding-top: 8px; font-size: 8pt; color: #9e9e9e; text-align: center; }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1 class="title">LAUDO DE DIAGNÓSTICO TÉCNICO AUTOMOTIVO</h1>
            <p class="subtitle">leitorECU — Scanner Automotivo Profissional | Emitido em {now_str}</p>
        </div>

        <div class="box">
            <h3 style="color:#1565c0;">Identificação do Veículo e da Central Eletrônica</h3>
            <table style="font-size:10pt;">
                <tr><td style="width:25%; font-weight:bold;">Central Detectada:</td><td>{display_title}</td></tr>
                <tr><td style="font-weight:bold;">Montadora / Origem:</td><td>{manufacturer}</td></tr>
                <tr><td style="font-weight:bold;">Chassi (VIN):</td><td><code>{vin}</code></td></tr>
                <tr><td style="font-weight:bold;">Protocolo Ativo:</td><td>{protocol}</td></tr>
            </table>
        </div>

        <div class="box">
            <h3 style="color:#d32f2f;">Diagnóstico de Falhas (DTC) — Luz de Injeção: {mil_status}</h3>
            <table style="font-size:10pt;">
                <thead><tr><th style="width:20%;">Código</th><th>Descrição da Falha</th></tr></thead>
                <tbody>{dtc_rows}</tbody>
            </table>
            {ff_content}
        </div>

        {"<div class='box'><h3 style='color:#2e7d32;'>Inspeção de Monitores de Prontidão (I/M Readiness)</h3><table style='font-size:9.5pt;'>" + readiness_rows + "</table></div>" if readiness_rows else ""}

        <div class="box">
            <h3 style="color:#f57f17;">Análise Elétrica e Teste de Partida</h3>
            <p style="font-size:10pt; margin:4px 0;">{battery_test}</p>
        </div>

        {"<div class='box'><h3 style='color:#37474f;'>Picos Registrados em Telemetria</h3><table style='font-size:9pt;'><thead><tr><th>Parâmetro</th><th>Mínimo</th><th>Máximo</th></tr></thead><tbody>" + peaks_rows + "</tbody></table></div>" if peaks_rows else ""}

        <div class="footer">
            Relatório gerado automaticamente por leitorECU — Datalogger & Scanner Universal.
        </div>
    </body>
    </html>
    """
    return html


def export_report_to_pdf(html_content: str, file_path: str) -> bool:
    """Exporta o laudo HTML diretamente para PDF usando QTextDocument e QPdfWriter nativos do Qt."""
    try:
        from PyQt6.QtGui import QPageSize, QPdfWriter
        doc = QTextDocument()
        doc.setHtml(html_content)
        writer = QPdfWriter(file_path)
        writer.setPageSize(QPageSize(QPageSize.PageSizeId.A4))
        doc.print(writer)
        return True
    except Exception:
        return False
