# Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)

App desktop **offline** (PyQt6 + PyQtGraph, 30 FPS) para ler a ECU via ELM327:
**Bluetooth BLE** (Vgate iCar Pro BLE 4.0), **Wi-Fi** (TCP 192.168.0.10:35000) ou **Demo/Simulador**.

## Instalação (uma vez, precisa de internet só neste passo)
```powershell
pip install -r requirements.txt
```
Depois disso o programa roda sem internet.

## Executar
```powershell
python main.py          # normal
python main.py --demo   # já abre no modo simulador
```

## Conectando o Vgate iCar Pro BLE 4.0
1. Plugue o adaptador na tomada OBD (embaixo do painel, lado do motorista) e **ligue a ignição**.
2. **NÃO pareie** o adaptador nas configurações de Bluetooth do Windows (BLE conecta direto pelo app).
   Se já pareou, remova o dispositivo no Windows.
3. Modo **Bluetooth BLE** → **🔍 Procurar BLE** → escolha o item com ★ (geralmente `IOS-Vlink`).
4. **Conectar**. O console mostra o handshake `ATZ, ATE0, ATL0, ATS0, ATH0, ATSP5, 0100`.
   O 1º `0100` (Fast Init na linha K) pode levar alguns segundos.
5. O PC precisa ter Bluetooth 4.0+ (BLE) e Windows 10/11. Feche outros apps (Torque, Car Scanner) no celular,
   pois o adaptador aceita só uma conexão.

## Recursos
| Recurso | Onde |
|---|---|
| Cards (RPM, MAP, Avanço, TPS, Sonda V, correção, STFT, LTFT, ECT + extras) | topo — amarelo/vermelho para trims > ±10/20%, sonda travada, ECT alta |
| Gráficos sincronizados (últimos 30 s) | centro: Ar/Giro, Combustão/Mistura (ref. 0,45 V e 0,70 V), Correção |
| ⚡ Prioridade de Desaceleração | lê só 010C/010B/010E/0111/0114 ou Bloco 003+033 (~1,6× a 2× mais amostras por sensor) |
| Resposta rápida (sufixo 1) | envia `010C1`: o ELM não espera timeout — costuma dobrar a taxa no iCar Pro (modo OBD2) |
| ⏺ Gravar Log | CSV `;` com vírgula decimal (abre direto no Excel pt-BR), timestamp em ms e todos os canais dinâmicos |
| Aba "Todos os Canais" | visualização em tempo real de todas as células e blocos de medição lidos da central |
| 🔎 Varredura de Blocos VAG | botão na aba Todos os Canais para varrer e catalogar todos os blocos suportados da ECU |
| Detector de Cut-Off | aba Eventos + marcador vertical nos gráficos |
| DTCs | aba Códigos de Falha: ler (03/Serviço 18), apagar (04/Serviço 14), status da luz de injeção |
| Console ELM327 | aba Console (marque “Console bruto” para ver todos os TX/RX) |

## Documentação Técnica para Desenvolvedores
Para detalhes completos de engenharia sobre a arquitetura do software, handshake VAG KWP2000 na Bosch ME7.5.30 brasileira e fórmulas de conversão, consulte o arquivo [AGENTS.md](AGENTS.md).

## Estrutura
```
main.py                     ponto de entrada
AGENTS.md                   documento de contexto técnico de engenharia e arquitetura
cache/                      cache local de blocos de medição descobertos por ECU
obd_app/transports.py       TCP, BLE (bleak) e Mock
obd_app/mock_engine.py      motor simulado (ciclos com e sem falha de cut-off)
obd_app/elm327.py           handshake, leitura até '>', classificação de erros, parser hex
obd_app/pids.py             PIDs Modo 01, fórmulas e canais semânticos
obd_app/vag.py              tabela universal de fórmulas VAG KWP2000 e gerenciamento de cache
obd_app/worker.py           QThread de polling + autodiscovery VAG KWP2000 / OBD2 + DTC
obd_app/detector.py         detector de desaceleração / cut-off
obd_app/datalog.py          CSV com colunas dinâmicas (Excel pt-BR) e buffers circulares
obd_app/dtc.py              decodificação de DTCs (Modo 03 e KWP2000 Serviço 18)
obd_app/ui/                 janela, cards, gráficos, abas e tema
```
