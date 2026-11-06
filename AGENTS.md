# AGENTS.md — Contexto de Engenharia & Arquitetura do Sistema

Documento de referência técnica completo para desenvolvedores e agentes de inteligência artificial sobre a arquitetura, protocolos e calibração da ECU implementados no projeto `leitorECU`.

---

## 1. Visão Geral do Projeto

O **leitorECU** é um aplicativo desktop multiplataforma (otimizado para Windows, escrito em Python 3.13+ com PyQt6 e PyQtGraph rodando a 30 FPS estáveis) para diagnóstico, aquisição de dados e telemetria de alta frequência voltado para múltiplos veículos:
1. **Volkswagen Gol G5, Voyage, Saveiro, Fox e Polo (1.0 e 1.6 8V TotalFlex EA111)**: Central **Bosch ME7.5.30** via protocolo proprietário **VAG KWP2000**.
2. **Ford Ka+ 2016 SEL Sedan (Motor Sigma 1.5 16V Flex DOHC - Comandos Fixos, sem VVT)**: Barramento **Ford HS-CAN 500 kbps** (ISO 15765-4 / UDS ISO 14229) com suporte multimodular completo:
   - **PCM** (0x7E0 / 0x7E8): Motor Sigma 1.5 DOHC com **duas sondas lambda** (Sonda 1 B1S1 pré-cat `0114` e Sonda 2 B1S2 pós-cat `0115` para diagnóstico de eficiência do catalisador), Status de Malha Aberta/Fechada `0103`, CHT, Pedal Acelerador APP %, Eletroventilador PWM %, Tempo de Injeção, Temp. Catalisador, Temp. Ar IAT, Pressão A/C e Etanol flex. *Nota técnica: O motor Sigma 1.5 do Ka 2014-2018 possui comandos fixos sem variadores de fase (sem VVT/Ti-VCT). Não confundir com o motor Sigma 1.6 Ti-VCT nem com o motor Dragon 1.5 de 3 cilindros.*
   - **BCM** (0x726 / 0x72E): Módulo de Carroceria e Conforto (status das 4 portas, porta-malas sedan, capô, travas elétricas, alarme PATS, farol baixo/alto, faróis de neblina, lanternas, limpadores, desembaçador, ignição, tensão BCM).
   - **ABS/ESC** (0x760 / 0x768): Velocidade individual das 4 rodas (FL, FR, RL, RR em km/h), pressão do freio no cilindro mestre, pedal de freio, sensor de ângulo SAS, status de intervenção ESC/HLA.
   - **IPC** (0x720 / 0x728): Painel de instrumentos (odômetro total em km, nível de combustível, temperatura externa, freio de mão, cinto).
   - **PSCM** (0x730 / 0x738): Direção elétrica progressiva EPAS (ângulo do volante, torque aplicado, corrente do motor elétrico).
   - **RCM** (0x737 / 0x73F): Módulo de airbags e retenção.

O sistema suporta:
- **Adaptadores ELM327 BLE (Bluetooth Low Energy / Bluetooth 4.0+)**: ex. Vgate iCar Pro BLE4.0 (`IOS-Vlink`).
- **Adaptadores ELM327 Wi-Fi / TCP**: conexão direta via socket `192.168.0.10:35000`.
- **Modo Demo / Simulador**: emulador de motor com injeção de falhas e física em tempo real para ambos os perfis (VW ME7.5.30 e Ford Ka+ HS-CAN).

---

## 2. A Descoberta Crítica da ECU Bosch ME7.5.30 Flex (Brasil)

### 2.1 O Problema do Modo 01 OBD-II Padrão
Quando um leitor OBD genérico (como Torque, Car Scanner ou scanners convencionais) conecta na Bosch ME7.5.30 com calibração TotalFlex brasileira via protocolo padrão ISO 9141-2 (endereço funcional `0x33` com header `68 6A F1`):
1. A central responde ao PID `0100` e aos PIDs básicos (`010C` RPM, `010B` MAP, `010E` Avanço, `0111` TPS, `0105` ECT).
2. A central declara no PID `0113` que tem 1 sensor O2 instalado (`o2_mask = 0x01`).
3. **Porém**, ao solicitar os PIDs de mistura `0114` (Sonda 1), `0115` (Sonda 2), `0106` (STFT) e `0107` (LTFT), a central retorna **`NO DATA`**! A calibração de fábrica da VW/Bosch para a ME7.5.30 brasileira suprime esses PIDs no Modo 01 convencional.

### 2.2 A Solução: Protocolo VAG KWP2000 Nativo (Modo 21 / ReadDataByLocalIdentifier)
Descobrimos que a ECU acorda no protocolo proprietário **VAG KWP2000** quando inicializada com:
- Protocolo ELM327: `ATSP4` (ISO 14230-4 KWP 5-baud init)
- Baudrate: `ATIB10` (10.400 baud)
- Endereço de inicialização: `ATIIA01` (endereço físico VAG do Módulo do Motor: `0x01`)
- Header de transmissão: `ATSH 81 10 F1` (formato KWP2000: destino `0x10` Motor OBD, origem `0xF1` Ferramenta de Diagnóstico)
- Mensagem de Wakeup/Keepalive: `ATWM 81 10 F1 3E` (Serviço `3E` = TesterPresent)
- Mensagens longas ativadas: `ATAL` (permite multi-frame de até 29 bytes por resposta)

Ao disparar o 5-baud init no endereço `01`, a central retorna os KeyBytes **`EF 8F`** e passa a responder nativamente aos comandos do Modo `21` (Blocos de Medição VAG):
- **Bloco 033 (`2121`)**: Retorna simultaneamente a **Correção da Sonda / STFT (%)** e a **Tensão da Sonda Lambda 1 (V)**, com oscilação contínua (ex.: 0,10 V a 0,75 V).
- **Bloco 032 (`2120`)**: Retorna a **Adaptação Lambda / LTFT em Lenta e Parcial (%)**.
- **Bloco 003 (`2103`)**: Retorna em um único frame de 12 bytes: **RPM**, **MAP (mbar/kPa)**, **TPS (%)** e **Avanço de Ignição (°)** (fórmula `0x1B`).
- **Bloco 004 (`2104`)**: Retorna **Bateria (V)**, **ECT (°C)** e **IAT (°C)**.
- **Bloco 005 (`2105`)**: Retorna **Carga (%)** e **Velocidade (km/h)**.
- **Bloco 031 (`211F`)**: Retorna a tensão bruta de ambas as sondas pré e pós catalisador.
- **Serviço 18 (`1800FF00`)**: Leitura nativa de códigos de falha (DTC) do protocolo VAG KWP2000.
- **Serviço 14 (`14FF00`)**: Limpeza de códigos de falha e adaptações da central.

---

---

## 3. O Barramento Ford HS-CAN 500 kbps (Ford Ka+ 2016 SEL 1.5 Sigma Sedan)

### 3.1 Topologia de Rede & Módulos Suportados
O Ford Ka de 3ª geração (B562) utiliza barramento CAN de alta velocidade (HS-CAN) a 500 kbps nos pinos 6 (CAN-H) e 14 (CAN-L) do conector OBD2:
- **PCM (0x7E0 / 0x7E8)**: Módulo do Motor Sigma 1.5 16V Flex DOHC (comandos fixos, sem VVT). Central Continental EMS2211.
  > *Atenção Técnica*: O motor Sigma 1.5 16V do Ka (geração B562, 2014-2018) possui duplo comando no cabeçote sem variador de fase (sem Ti-VCT / VVT). Não deve ser confundido com o motor 1.5 Dragon de 3 cilindros (que possui Ti-VCT) nem com o Sigma 1.6 Ti-VCT do New Fiesta.
- **BCM (0x726 / 0x72E)**: Módulo de Carroceria e Conforto (GEM).
- **ABS/ESC (0x760 / 0x768)**: Módulo de Freios ABS, Controle de Estabilidade e Assistente de Partida em Rampa (HLA).
- **IPC (0x720 / 0x728)**: Painel de Instrumentos.
- **PSCM (0x730 / 0x738)**: Direção Elétrica Progressiva (EPAS).
- **RCM (0x737 / 0x73F)**: Módulo de Airbags e Retenção.

### 3.2 Protocolo UDS Ford (Modo 22 - ReadDataByIdentifier)
- Inicialização ELM327: `ATSP6` (ISO 15765-4 CAN 11/500k), `ATAL`, `ATCAF1`, `ATC1`, `ATSH 7E0`.
- **BCM Conforto (`ATSH 726`)**:
  - `22404C`: Status das 4 portas (DE, DD, TE, TD), porta-malas sedan, capô e travas elétricas.
  - `224050`: Status de iluminação (farol baixo, farol alto, neblina, lanternas, setas, pisca-alerta).
  - `224060`: Limpadores de para-brisa, desembaçador traseiro, ignição (Off/Acc/Run/Crank) e alarme PATS.
  - `224001`: Tensão da bateria medida diretamente pelo BCM.
- **ABS & Estabilidade (`ATSH 760`)**:
  - `222B00`: Velocidade individual das 4 rodas em tempo real (km/h).
  - `222B01`: Pressão no cilindro mestre de freio (bar), pedal de freio, sensor de ângulo de esterçamento (SAS) e intervenção ESC/HLA.
- **PCM Motor Sigma (`ATSH 7E0`)**:
  - `0114` (PID Modo 01): Sonda Lambda 1 (B1S1 pré-catalisador) — tensão oscilante (0.1V - 0.9V) e STFT do sensor.
  - `0115` (PID Modo 01): Sonda Lambda 2 (B1S2 pós-catalisador) — monitoramento da eficiência catalítica (~0.60V - 0.75V estável).
  - `0103` (PID Modo 01): Status do Sistema de Combustível (Malha Aberta / Malha Fechada / WOT).
  - `010F` (PID Modo 01): Temperatura do Ar de Admissão no coletor T-MAP (IAT °C).
  - `013C` / `221627`: Temperatura estimada do monólito do catalisador (°C).
  - `0142`: Tensão do módulo de controle (PCM interno em V).
  - `0133` / `220320`: Pressão barométrica absoluta (kPa).
  - `221624`: Temperatura da Cabeça do Cilindro (CHT °C) — o Sigma não usa sensor ECT direto na água, mas sim CHT seco na carcaça.
  - `22032B`: Posição do sensor do pedal do acelerador APP (%).
  - `220332`: Ciclo de trabalho do eletroventilador de arrefecimento (PWM Duty Cycle %).
  - `221125`: Tempo de injeção dos bicos injetores (Pulse Width ms).
  - `221101`: Pressão do refrigerante do ar condicionado (kPa) e status do compressor.
  - `221608`: Nível de etanol flex virtual calculado pela central (%).
- **IPC Painel (`ATSH 720`)**:
  - `22DD01`: Odômetro total em km.
  - `222416`: Nível de combustível (%), temperatura externa (°C), alertas de cinto e freio de mão.
- **PSCM Direção (`ATSH 730`)**:
  - `223300`: Ângulo do volante (°), torque aplicado pelo motorista (Nm) e corrente do motor EPAS (A).

---

## 4. Arquitetura do Software & Princípios SOLID

A base de código foi arquitetada seguindo rigorosamente os princípios **SOLID**:
- **S (Single Responsibility)**: Separação estrita entre camada física (`transports.py`), protocolo AT (`elm327.py`), estratégias veiculares (`protocols/`), orquestrador assíncrono (`worker.py`) e visualização (`ui/`).
- **O (Open/Closed)**: Aberto para extensão, fechado para modificação. Adicionar um novo veículo (ex: Fiat Firefly, GM Onix) exige apenas criar uma nova classe herdando de `BaseVehicleStrategy`, sem tocar no loop do worker.
- **L (Liskov Substitution)**: Todas as estratégias veiculares e transportes físicos implementam interfaces polimórficas (`IVehicleStrategy`, `ITransport`) e podem ser substituídas de forma intercambiável.
- **I (Interface Segregation)**: Interfaces enxutas e focadas (`ITransport`, `IDataLogger`, `IDetector`, `IVehicleStrategy`) evitando acoplamento desnecessário.
- **D (Dependency Inversion)**: O orquestrador `ObdWorker` depende de abstrações (`IVehicleStrategy` e `ITransport`), injetadas via Factory.

```
leitorECU/
├── main.py                     # Entry point do aplicativo Qt (--demo para simulador)
├── requirements.txt            # Dependências (PyQt6, pyqtgraph, numpy, bleak, pytest)
├── README.md                   # Manual de usuário e guia rápido
├── AGENTS.md                   # Este arquivo (contexto de engenharia completo)
├── .gitignore                  # Exclusão de pycache, logs e arquivos temporários
├── cache/                      # Cache local de blocos suportados por ECU (JSON)
│   └── vag_blocos_032906032AJ.json
├── tests/                      # Suite completa de testes automatizados (pytest)
│   ├── conftest.py             # Configuração e fixtures compartilhadas
│   ├── test_pids.py            # Fórmulas Modo 01 e independência de Sonda 1 e 2
│   ├── test_ford.py            # DIDs UDS Ford (BCM, ABS, PCM Sigma 1.5 DOHC, IPC, EPAS)
│   ├── test_vag.py             # Fórmulas VAG (0x01..0x46) e blocos de medição
│   ├── test_datalog.py         # Gravação CSV pt-BR (;) e colunas dinâmicas
│   ├── test_detector.py        # Detector de Cut-Off e desaceleração
│   ├── test_dtc.py             # Parser de DTCs (Modo 03 e Serviço 18)
│   ├── test_strategies.py      # Testes de estratégias e polimorfismo SOLID
│   └── test_ui_smoke.py        # Testes de conformidade de UX e resolução 1080p
└── obd_app/
    ├── __init__.py
    ├── interfaces.py           # Protocolos e interfaces abstratas (SOLID: DIP/ISP)
    ├── protocols/              # Estratégias de comunicação veicular (SOLID: OCP/LSP)
    │   ├── __init__.py         # Registry e factory de estratégias
    │   ├── base.py             # BaseVehicleStrategy (Template Method)
    │   ├── vag.py              # VagKwpStrategy (VW ME7.5.30 KWP2000)
    │   ├── ford.py             # FordHsCanStrategy (Ford Ka+ 2016 HS-CAN)
    │   └── generic.py          # GenericObdStrategy (OBD2 Padrão)
    ├── transports.py           # Camada de comunicação física (BLE via bleak, TCP socket, Mock)
    ├── elm327.py               # Protocolo AT ELM327, extração de payload hex e tratamento de erro
    ├── pids.py                 # Definição de canais fixos, PIDs Modo 01 e fórmulas
    ├── vag.py                  # Fórmulas universais VAG KWP2000 e cache de blocos
    ├── ford.py                 # Mapeamento de DIDs Ford HS-CAN 500k e decodificadores
    ├── worker.py               # QThread orquestradora: ciclo de vida, reconexão e sinais
    ├── datalog.py              # CsvLogger com colunas dinâmicas (Excel pt-BR) e SeriesBuffer
    ├── detector.py             # Detector em tempo real de desaceleração, cut-off e falhas
    ├── dtc.py                  # Parser e descritor de DTCs (Modo 03 e KWP Serviço 18)
    ├── mock_engine.py          # Simulador com física de motor ME7.5 e Ford Ka+ HS-CAN
    └── ui/
        ├── __init__.py
        ├── main_window.py      # Janela principal PyQt6 (cards, abas, render loop a 30 FPS)
        ├── plots.py            # Gráficos sincronizados com duplo eixo Y (DualAxisPlot)
        ├── widgets.py          # ValueCard com animação de alerta (normal, warn, alarm, stale)
        └── style.py            # Tema Dark automotivo profissional e paleta de cores
```

---

## 5. Fluxo de Dados e Ciclo de Vida da Conexão

```
[UI / MainWindow]
       │
       ▼ (inicia)
[ObdWorker (QThread)]
       │
       ├─► 1. Handshake do Adaptador (ATZ, ATE0, ATL0, ATS0, ATH0, ATAL)
       │
       ├─► 2. Tenta Handshake VAG KWP2000:
       │      ATSP4 -> ATIB10 -> ATKW0 -> ATIIA01 -> ATSH8110F1 -> 1089 -> 2121
       │      │
       │      ├─► [Sucesso VAG KWP2000]:
       │      │   - Lê ID da ECU (1A9B -> ex: 032906032AJ ME7.5.30)
       │      │   - Carrega cache de blocos (vag.py)
       │      │   - Define active_fast = [2103, 2121] (4 sensores/pacote + Sonda/STFT)
       │      │   - Define active_normal = [2103, 2121, 2120, 2104]
       │      │   - Em segundo plano: testa grupos 001..255 (1 por ciclo)
       │      │   - Emite canais dinâmicos para a UI e CSV
       │      │
       │      └─► [Falha / Não-VAG / Demo]:
       │          - Fallback para OBD-II genérico (0100 -> ATSP0/ATSP3/ATSP5)
       │          - Autodiscovery do bitmap de PIDs (0100, 0120, 0140)
       │          - Sondagem de PIDs Modo 01 (0114, 0106, 0107, etc.)
       │
       └─► 3. Loop de Polling (30 FPS):
              - Lê ciclo de PIDs rápidos/lentos
              - Decodifica dados brutos -> floats
              - Emite sinal Qt: sample(t_rel, wall_ms, values_dict)
              - DecelDetector analisa transições de Cut-Off
              - CsvLogger grava linha em tempo real
              - Gráficos e Cards atualizados via QTimer a 30 FPS
```

---

## 5. Mapeamento dos Blocos de Medição VAG (KWP2000 Serviço 21)

A resposta do serviço `21` é formatada como:
`61 [Grupo_Hex] [Célula 1: k, A, B] [Célula 2: k, A, B] [Célula 3: k, A, B] [Célula 4: k, A, B] ...`

O byte `k` define a fórmula matemática a ser aplicada aos bytes `A` e `B`. O módulo `vag.py` implementa a tabela completa de fórmulas VAG (fórmulas `0x01` a `0x46`). Abaixo estão as mais relevantes para injeção eletrônica:

| Código `k` | Fórmula | Unidade | Aplicação Comum |
|:---:|:---:|:---:|:---|
| `0x01` | $0.2 \times A \times B$ | rpm | Rotação do motor (RPM) |
| `0x02` | $0.002 \times A \times B$ | % | Carga do motor |
| `0x03` | $0.002 \times A \times B$ | ° | Ângulo de borboleta |
| `0x04` | $\pm 0.01 \times A \times \|B - 127\|$ | ° | Ângulo de avanço / atraso |
| `0x05` | $0.1 \times A \times (B - 100)$ | °C | ECT (arrefecimento), IAT (ar), Óleo |
| `0x06` | $0.001 \times A \times B$ | V | Tensão da Sonda Lambda |
| `0x07` | $0.01 \times A \times B$ | km/h | Velocidade do veículo |
| `0x0B` | $0.0001 \times A \times (B - 128) + 1.0$ | $\lambda$ | Fator Lambda |
| `0x0E` | $0.005 \times A \times B$ | bar | Pressão de combustível / turbo |
| `0x0F` | $0.01 \times A \times B$ | ms | Tempo de injeção (TI) |
| `0x12` | $0.04 \times A \times B$ | mbar | Pressão do coletor (MAP) |
| `0x14` | $A \times (B - 128) / 128.0$ | % | Correção de Sonda (STFT / LTFT) |
| `0x15` | $0.001 \times A \times B$ | V | Tensão de bateria ou sinal analógico |
| `0x1B` | $0.01 \times A \times (B - 128)$ | ° | Avanço de ignição na ME7.5.30 |
| `0x21` | $100.0 \times B / A$ | % | Abertura do pedal / borboleta |

---

## 6. O Sistema de Gravação CSV com Colunas Dinâmicas

O `CsvLogger` ([`obd_app/datalog.py`](file:///c:/Users/rsaho/Desktop/leitorECU3/leitorECU/leitorECU/obd_app/datalog.py)) foi desenhado para garantir que **absolutamente todos os sensores e blocos descobertos sejam gravados**:

1. **Colunas Fixas Padronizadas**:
   `timestamp_ms; tempo_s; atualizado; rpm; map; advance; tps; lambda_v; lambda_trim; stft; ltft; ect; load; speed; iat; battery; lambda2_v; ...`
2. **Colunas Dinâmicas Automáticas**:
   Conforme a ECU envia novos blocos de medição (ex: `g002_c2`, `g020_c1`, `g060_c1`), o logger registra essas colunas e atualiza o cabeçalho do arquivo com descrições humanas (ex: `Bloco 020.1 Retardo detonação cil. 1 [°KW]`).
3. **Padrão Excel pt-BR**:
   Usa delimitador `;` e vírgula decimal para abrir nativamente com um duplo-clique no Excel sem necessidade de assistente de importação.
4. **Flush Seguro**:
   A cada 0,5 segundo o buffer do sistema operacional é liberado em disco (`flush()`), evitando perda de dados caso o cabo seja desconectado bruscamente.

---

## 8. Arquitetura Refatorada (SOLID, Replay & Diagnóstico Avançado)

### 8.1 Unificação de Decodificadores e Telemetria ME7.5.30
* **Fonte Única (`vag.py`)**: `decode_vag_cell` em `pids.py` delega diretamente para `decode_cell` de `vag.py`, eliminando duplicatas de fórmulas.
* **Tempo de Injeção Real (`inj_ms`)**: Bloco 002 (Célula 3) decodificado e mapeado para o canal `inj_ms` em `CHANNELS`.
* **Status de Malha VAG (`fuel_sys1`)**: Bloco 005 (Célula 4) decodificado bit a bit: Cut-Off/Schubabschaltung (`1.0`), Malha Fechada (`2.0`), WOT/Plena Carga (`4.0`).
* **Multi-frame sem Deslocamento**: `vag.extract_block()` e `elm327.py` tratam repetições de prefixos de frame (`0:`, `1:`) e cabeçalhos `61 GG`, prevenindo corrupção de unidades no cache JSON.
* **Rotação Inteligente Linha K**: Em cada ciclo normal lê `active_fast` (003 e 033) e intercala 002, 004, 005 e 032 a cada 4 ciclos, dobrando a taxa de amostragem útil (Hz). Varredura de blocos secundários desativada por padrão e controlada por checkbox na UI.

### 8.2 Proteção contra Fallback Silencioso & Badge de Protocolo
* Emissão do sinal `protocol_mode_changed(name, is_fallback)` para badge visual (`[VAG KWP2000 Nativo]` em verde vs `[Fallback ISO 9141-2]` em laranja).
* Botão `🔄 Forçar VAG KWP` para recuperação sem reiniciar o app.

### 8.3 Diagnóstico de Anomalias (Detector ME7.5.30)
* **Conflito de Carga / Vácuo Baixo**: `rpm < 1900`, `tps < 8%`, `map > 60 kPa` -> alerta imediato de travamento de dashpot ou ar falso.
* **Retardo Crítico ATDC**: `advance < -8.0°` (ex: `-19°`) -> alerta de risco de detonação/combustão no escape.

### 8.4 Modo Replay CSV & Mapa 2D (RPM × MAP)
* **Replay de CSV**: Botão `📂 Abrir Log CSV` carrega qualquer log gravado, renderiza os gráficos completos, permite pan/zoom livre e adiciona **Crosshair sincronizado** que atualiza dinamicamente os 14 cards do topo ao mover o cursor.
* **Mapa 2D Térmico**: Grade RPM × MAP (700 a 5500 RPM × 20 a 100 kPa) acumulando médias de Avanço de Ignição (°), STFT (%) ou Sonda Lambda (V). Coloração especial em magenta/roxo para zonas de retardo negativo (`-19°`).
* **Peak Hold nos Cards**: Mínimo e Máximo exibidos no canto inferior esquerdo de cada ValueCard com botão `⚡ Limpar Picos`.

### 8.5 Suite de Testes Automatizados (39 Testes)
```bash
py -3.13 -m pytest tests/ -v
# 39 passed in ~6s (100% sucesso)
```


Ao realizar modificações ou expansões no código:

1. **Nunca quebrar a prioridade VAG KWP2000**:
   A sequência `ATPC` -> `ATSP4` -> `ATIIA01` -> `ATSH8110F1` é essencial para a leitura de sonda lambda na central Bosch ME7.5.30 brasileira. Não substitua por `ATSP0` como default primário sem testar o fallback.
2. **Gerenciamento de Multi-Frame do ELM327**:
   Em modo VAG KWP2000 (`vag_kwp_mode = True`), o sufixo `'1'` do ELM327 (`fast_reply`) **não pode ser usado**, pois o comando `21 XX` retorna frames longos (~29 bytes) que seriam truncados no primeiro segmento de 7 bytes.
3. **Preservação de Integridade de Repositório**:
   - Manter o `.gitignore` atualizado para nunca versionar pastas `__pycache__/`, arquivos `.pyc`, logs `.csv` ou temporários `.tmp`.
   - NUNCA commitar endereços MAC de hardware físico do usuário no código-fonte principal (usar variáveis de configuração `QSettings`).
4. **Thread Safety**:
   Toda comunicação entre o `ObdWorker` (thread em background) e a `MainWindow` (thread principal da interface gráfica) deve obrigatoriamente trafegar por sinais Qt (`pyqtSignal`). Nunca acesse atributos da interface gráfica diretamente de dentro da QThread.
5. **Modo Mudo / Pausa da Linha K**:
   A Linha K do Gol G5 compartilha chicote próximo aos tweeters de áudio. O seletor de cadência com opção de pausa ("Pausar Linha K") evita indução de ruído acústico quando o carro está parado. Mantenha essa funcionalidade preservada.

