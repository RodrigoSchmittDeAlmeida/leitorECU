# AGENTS.md — Contexto de Engenharia & Arquitetura do Sistema

Documento de referência técnica completo para desenvolvedores e agentes de inteligência artificial sobre a arquitetura, protocolos e calibração da ECU implementados no projeto `leitorECU`.

---

## 1. Visão Geral do Projeto

O **leitorECU** é um aplicativo desktop multiplataforma (otimizado para Windows, escrito em Python 3.13+ com PyQt6 e PyQtGraph rodando a 30 FPS estáveis) para diagnóstico, aquisição de dados e telemetria de alta frequência voltado para múltiplos veículos:
1. **Volkswagen Gol G5, Voyage, Saveiro, Fox e Polo (1.0 e 1.6 8V TotalFlex EA111)**: Central **Bosch ME7.5.30** via protocolo proprietário **VAG KWP2000**.
2. **Ford Ka+ 2016 SEL Sedan (Motor Sigma 1.5 16V Flex DOHC - Comandos Fixos, sem VVT)**: Barramento **Ford HS-CAN 500 kbps** (ISO 15765-4 / UDS ISO 14229) com suporte multimodular completo:
   - **PCM** (0x7E0 / 0x7E8): Motor Sigma 1.5 DOHC (RPM, MAP, TPS, Avanço, Sondas, CHT, Pedal Acelerador APP %, Eletroventilador PWM %, Tempo de Injeção, Pressão A/C, Etanol flex). *Nota técnica: O motor Sigma 1.5 do Ka 2014-2018 possui comandos fixos sem variadores de fase (sem VVT/Ti-VCT). Não confundir com o motor Sigma 1.6 Ti-VCT nem com o motor Dragon 1.5 de 3 cilindros.*
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

## 4. Arquitetura do Software

```
leitorECU/
├── main.py                     # Entry point do aplicativo Qt (--demo para simulador)
├── requirements.txt            # Dependências (PyQt6, pyqtgraph, numpy, bleak)
├── README.md                   # Manual de usuário e guia rápido
├── AGENTS.md                   # Este arquivo (contexto de engenharia completo)
├── .gitignore                  # Exclusão de pycache, logs e arquivos temporários
├── cache/                      # Cache local de blocos suportados por ECU (JSON)
│   └── vag_blocos_032906032AJ.json
└── obd_app/
    ├── __init__.py
    ├── transports.py           # Camada de comunicação física (BLE via bleak, TCP socket, Mock)
    ├── elm327.py               # Protocolo AT ELM327, extração de payload hex e tratamento de erro
    ├── pids.py                 # Definição de canais fixos, PIDs Modo 01 e fórmulas VAG
    ├── vag.py                  # Módulo genérico de blocos VAG (tabela de 70+ fórmulas k, cache JSON)
    ├── ford.py                 # Módulo de diagnóstico Ford HS-CAN 500k e DIDs Modo 22 UDS
    ├── worker.py               # QThread principal: handshake, autodiscovery, polling e DTC
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

## 7. Diretrizes para Agentes e Futuras Modificações

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

