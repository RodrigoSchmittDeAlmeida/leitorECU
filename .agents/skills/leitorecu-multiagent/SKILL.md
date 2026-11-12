---
name: leitorecu-multiagent
description: >-
  Workflow multi-agente oficial do projeto leitorECU (CTO -> Tech Lead -> Workers
  Especialistas -> QA/Reviewer Independente) com memória compartilhada append-only
  no Vault do Obsidian (LOG-MESTRE.md, Kanban e ADRs). Use em qualquer sessão,
  refatoração, adição de protocolo/ECU, feature de UI ou auditoria neste projeto.
---

# `leitorecu-multiagent` — Protocolo Oficial de Engenharia & Swarm

## 1. Localizações Canônicas

- **Vault Obsidian (Memória Compartilhada):** `C:\Users\rsaho\Desktop\leitorECU-Obsidian`
- **Repositório Git (`leitorECU`):** `C:\Users\rsaho\Desktop\leitorECU3\leitorECU\leitorECU`
- **Log Mestre (Append-Only):** `C:\Users\rsaho\Desktop\leitorECU-Obsidian\04-Logs-de-Agentes\LOG-MESTRE.md`
- **Kanban:** `C:\Users\rsaho\Desktop\leitorECU-Obsidian\02-Sprints-e-Tasks\KANBAN.md`
- **ADRs & Arquitetura:** `C:\Users\rsaho\Desktop\leitorECU-Obsidian\01-Arquitetura-e-ADRs\`
- **Checklist QA:** `C:\Users\rsaho\Desktop\leitorECU-Obsidian\03-Code-Reviews\README.md`

---

## 2. Regra Obrigatória Antes e Depois de Toda Tarefa

Todo agente (Tech Lead, Workers, QA ou operador de IA externa) **DEVE**:

1. **Antes de agir:**
   - Ler as últimas entradas de `04-Logs-de-Agentes/LOG-MESTRE.md`.
   - Verificar os cards ativos em `02-Sprints-e-Tasks/KANBAN.md` e os ADRs relevantes em `01-Arquitetura-e-ADRs/`.
2. **Ao finalizar:**
   - Adicionar uma nova entrada **ao final** de `LOG-MESTRE.md` (nunca apagar ou editar entradas antigas), informando: data/hora, agente/modelo, card/demanda, resumo do que foi feito, arquivos criados/alterados, testes/comandos exatos executados + resultado real, e pendências para o próximo agente.

---

## 3. Hierarquia & Distribuição de Modelos

| Nível | Papel | Modelo Recomendado | Responsabilidade |
| :--- | :--- | :--- | :--- |
| 1 | **CTO** | Humano | Prioridades, aprovação de ADRs, validação no carro e *Go/No-Go* (`git commit`/release). |
| 2 | **Tech Lead / Coordenador** | Alta capacidade (ex.: `gemini-4-hydrogen-high`) | Quebra em tasks sem colisão, coerência SOLID, revisão final e gate pré-CTO. |
| 3 | **Workers Especialistas** | Econômico/Rápido (`flash` / `flash_lite`) | Implementação focada por módulo (`protocols/`, `math_channels/`, `ui/`) ou auditoria read-only (`inherit`). Usar `workspace: "share"` ou arquivos estritamente disjuntos quando rodando em paralelo. |
| 4 | **QA / Reviewer** | Independente (`inherit`) | Executa `py -3.13 -m pytest tests/ -v`, valida UI (`1920x1080`) e checklist de `03-Code-Reviews/README.md`. **Não escreve features.** |
| 5 | **IAs Externas** | DeepSeek / Ollama (opcional) | Apenas rascunhos/sugestões. **Proibido** aplicar código ou commitar sem revisão linha a linha de Worker + Tech Lead + QA. |

---

## 4. Regras Invioláveis do Projeto

- **Zero commits automáticos:** nunca rodar `git commit` ou `git push` sem ordem explícita do CTO.
- **SOLID:** manter contratos em `obd_app/interfaces.py` e estratégias desacopladas em `obd_app/protocols/`.
- **Segurança automotiva:** nunca disparar comandos de escrita/reset (`14FF00`, `2800`, `31xx`, `2Exxxx`) sem comando explícito do usuário.
- **Qualidade:** nenhum "pass" reportado sem rodar `py -3.13 -m pytest tests/ -v` após a última edição.
