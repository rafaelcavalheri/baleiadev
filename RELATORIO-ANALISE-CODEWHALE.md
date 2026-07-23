# Relatório de Análise — Fork CodeWhale (baleiadev)

**Data:** 2026-07-14
**Repo:** `code/CodeWhale` — fork de `Hmbown/CodeWhale` → `rafaelcavalheri/baleiadev`
**Branch analisado:** `feature/acp-filesystem-tools` (2 commits à frente de `main` local; `main` local está **62 commits atrás** de `origin/main`)

---

## 1. O que é o projeto e como funciona

CodeWhale é um agente de código para terminal (estilo Claude Code / Codex CLI), escrito em Rust (~490 mil linhas), MIT, multi-provider (DeepSeek, Anthropic, OpenRouter, Ollama, vLLM etc.). Fluxo central:

1. **Entrada** — TUI (ratatui), `codewhale exec` (headless), API HTTP/SSE (`runtime_api`), servidor MCP e servidor **ACP** (stdio, para editores como Zed).
2. **Engine** (`crates/tui/src/core/engine*`) — loop de turno com streaming: mensagem → LLM → tool calls → aprovação/sandbox/hooks → resultado → repete. Pós-edição roda hook LSP que injeta diagnósticos.
3. **Ferramentas** (`crates/tui/src/tools/`) — file/search/git/patch/shell, subagentes, tasks duráveis, RLM (REPL Python), MCP client. Confinamento de caminho ao workspace em `tools/spec.rs::resolve_path` (com canonicalização — bem feito).
4. **Segurança** — 3 modos (Plan read-only), postura de aprovação separada, sandbox por SO (Seatbelt no macOS ativo; **Linux/Windows ainda sem enforcement real**), snapshots side-git para `/restore`, "constitution" por repo.
5. **Durabilidade** — sessões/threads/tasks em SQLite + JSON com `schema_version` gates; Fleet com ledger append-only.

## 2. Ponto estrutural crítico: o god-crate `tui`

| Crate | Linhas | Observação |
|---|---|---|
| `crates/tui` | **~427.000** | Contém engine, client LLM, tools, runtime API, TUI, MCP, LSP, fleet… |
| demais 17 crates | ~63.000 | extração incremental em andamento |

Arquivos gigantes dentro do `tui`: `main.rs` (12.084 linhas), `tui/ui.rs` (13.623), `config.rs` (~7.000 + 274 KB), `client.rs` (196 KB), `mcp.rs` (102 KB), `compaction.rs` (100 KB).

**Consequências práticas para o fork:** qualquer mudança recompila o crate inteiro (builds lentos), conflitos de merge com upstream são quase garantidos em `main.rs`/`ui.rs`, e testar unidades isoladas é difícil. O upstream reconhece isso (nota de fronteira no ARCHITECTURE.md) e está extraindo crates — **alinhar suas contribuições a essa direção aumenta a chance de merge**.

## 3. Análise do seu trabalho ACP (`crates/tui/src/acp_server.rs`, 2.289 linhas)

### Pontos fortes
- Streaming real de deltas com cancelamento concorrente (`tokio::select!` entre stream do provider e leitor de stdin) — desenho correto e bem comentado.
- Reuso do `ToolRegistry` existente (sem duplicar implementação de filesystem/shell) — exatamente o que o upstream pede.
- Tool calls malformados viram `tool_result` de erro em vez de travar o turno.
- Cancelamento sinaliza `CancellationToken` e **aguarda** a ferramenta encerrar (mata processo filho) antes de retornar — cuidado raro de se ver.
- 33 testes unitários no módulo, com streams em memória (não dependem de provider real).
- Cap de rounds (`MAX_ACP_TOOL_ROUNDS = 50`) e de sessões (64).

### Pontos críticos (em ordem de severidade)

1. **Shell total sem aprovação** (`acp_server.rs:1041-1060`): `auto_approve = true` + `ShellPolicy::Full` para qualquer cliente que não declare `terminal: false` — e o default quando o campo é omitido é **permissivo** (`client_supports_terminal: true`, linha 714). O ACP tem `session/request_permission` no protocolo; implementá-lo (com fallback para negar comandos `SafetyLevel::Dangerous` quando o cliente não suportar) é a melhoria de maior valor para o merge upstream — o comentário no código admite a lacuna ("ACP has no per-tool approval round-trip **yet**"). No Windows, onde não há sandbox nenhum, isso significa execução arbitrária irrestrita.

2. **Eviction de sessão é aleatória, não "oldest"** (`acp_server.rs:798-809`): o comentário diz que HashMap retém ordem de inserção — **não retém**; a ordem de iteração é arbitrária. Com 64 sessões, `session/new` pode despejar a sessão mais recente. Corrigir com `IndexMap`, um contador de inserção, ou `VecDeque` de chaves.

3. **Comentário de `commit_turn_messages` contradiz o código** (`acp_server.rs:944-948` vs `161-172`): o doc diz "NOT on cancel, which preserves the pre-turn state", mas o loop principal **comita** o histórico parcial no cancel (após remover o assistant com tool_use pendente). O comportamento do código parece o desejado; o comentário está obsoleto — num PR upstream isso derruba a confiança do revisor.

4. **Histórico fica sujo em erro de provider**: `begin_prompt` empurra a mensagem do usuário direto em `session.messages` antes do turno; se `run_agentic_prompt_turn` retornar `Err` (erro de stream/rota), nada desfaz — o próximo prompt terá dois turnos `user` consecutivos. Empurrar a mensagem só no commit (ou remover no caminho de erro) resolve.

5. **`ScopedCurrentDir` muta o CWD do processo** por prompt (`acp_server.rs:967`): funciona porque o turno é single-flight, mas é estado global — se o ACP um dia atender turnos concorrentes (ver item 6) isso quebra silenciosamente sessões com `cwd` diferentes. Vale registrar como dívida ou passar o cwd explicitamente pela rota.

6. **Single-flight rejeita qualquer request durante um turno** (`-32603`, `acp_server.rs:432-444`): editores multi-sessão (Zed abre uma sessão por painel) vão receber erro em `session/new`/`session/prompt` de outra sessão enquanto um turno roda. Aceitável como baseline documentado, mas é a limitação funcional mais visível.

7. **Parâmetros hardcoded**: `max_tokens: 4096` (curto para modelos atuais), `temperature 0.2`, `top_p 0.9` (`acp_server.rs:1007-1024`). O TUI resolve budget pela rota real — o caminho ACP deveria usar o mesmo mecanismo.

8. **Sem compaction nem prompt caching no caminho ACP**: sessões longas estouram contexto (o TUI tem `compaction.rs`, o ACP não usa) e `cache_control: None` desperdiça caching da Anthropic em históricos que só crescem.

9. **Capacidade `fs` do cliente ignorada**: ACP permite delegar leitura/escrita ao editor (respeitando buffers não salvos). Hoje o agente lê do disco — editar um arquivo com mudanças não salvas no editor perde/ignora essas mudanças. É o próximo passo natural depois das permissões.

## 4. Pontos críticos do repositório como um todo

1. **2.678 `unwrap()` em 146 arquivos** (fora de testes há muitos: `snapshot/repo.rs` 119, `project/init.rs` 101, `config/config.rs` 96, `working_set.rs` 88, `fleet/ledger.rs` 66…). O perfil release mantém unwinding justamente porque a TUI supervisiona panics, mas cada unwrap num caminho de tool é um turno perdido. Um lint `clippy::unwrap_used` por módulo novo evitaria regressão.
2. **Sandbox Windows inexistente** (documentado em `sandbox/windows.rs` e ARCHITECTURE.md): "Full Access" no Windows = zero contenção de SO. Como você desenvolve no Windows, é um bom nicho de contribuição (Job Objects + tokens restritos), e o upstream já deixou o "helper contract" pronto.
3. **Docs com drift**: ARCHITECTURE.md ainda descreve o client como "DeepSeek Client", cita endpoints DeepSeek como padrão e caminhos legados `~/.deepseek`. Para quem entra no projeto (ou num fork), o doc de arquitetura desatualizado custa caro. Há gates de drift no CI para README/providers, mas não para ARCHITECTURE.md.
4. **CI forte, mas pesado**: fmt + clippy `--all-features` + testes em 3 SOs + cargo-deny + audit + vários gates de política (créditos de contribuidor, drift de tradução). Bom sinal de maturidade; para o fork, rodar `cargo clippy --workspace --locked` localmente antes de push economiza ciclos.
5. **Upstream veloz**: 62 commits de distância em ~2 dias. Fork de longa duração vai apodrecer rápido; a estratégia deve ser **PRs pequenos e frequentes para upstream** + rebase contínuo, não divergência acumulada.

## 5. Recomendações priorizadas (atualizado 2026-07-14 após commits de fix)

### Curto prazo (destravar o merge upstream do ACP)
- [x] ~~1. Implementar `session/request_permission`~~ → **parcial**: protocolo de permissão ACP ainda não existe no spec; `terminal` agora default `false` (82c9685d), e `auto_approve=true` documentado como limitação (f5393549). Pendente real: implementar round-trip de aprovação quando o spec evoluir.
- [x] **2. Corrigir eviction + comentário `commit_turn_messages`** — ✅ feito em 82c9685d (VecDeque para ordem verdadeira de inserção) e f5393549 (comentários alinhados).
- [x] **3. Desfazer push da mensagem do usuário no erro** — ✅ feito em 82c9685d (`roll back the pushed user message when a turn errors`).
- [x] **4. Resolver `max_tokens` pela rota** — ✅ feito em 82c9685d (`effective_max_output_tokens_for_route` substitui o 4096 fixo).

### Médio prazo
- [ ] 5. Usar a capability `fs` do cliente ACP (buffers não salvos do editor).
- [ ] 6. Compaction + `cache_control` no caminho ACP para sessões longas.
- [ ] 7. `session/load` (retomar sessões) e turnos concorrentes por sessão — remover o single-flight e, junto, o `ScopedCurrentDir` global.

### Longo prazo / posicionamento do fork
- [ ] 8. Contribuir na extração de crates do `tui` (o ACP server é candidato natural a `crates/acp` — depende só de client + tools + config); reduz conflito de rebase e builds.
- [ ] 9. Sandbox Windows via Job Objects — lacuna reconhecida, alto impacto, pouca competição.
- [ ] 10. Política de fork: manter `main` espelhando upstream, features em branches curtos, rebase semanal no mínimo (62 commits/2 dias de velocidade upstream).

### Itens adicionais resolvidos (além das recomendações originais)
- [x] **stopReason inválido** (82c9685d): `max_turns` → `max_turn_requests` conforme spec ACP. Clientes que usam `agent-client-protocol` crate não conseguiam desserializar a resposta.
- [x] **Prompt construction** (f5393549): agora usa `compose_prompt_with_approval_model_and_shell` + `load_project_context` (AGENTS.md, CLAUDE.md, rules) em vez de string fixa.
- [x] **Metadados de shell tools** (f5393549): `exec_shell_wait/interact/cancel` mapeados em `tool_call_kind` e `tool_call_title`.
- [x] **Cancelamento mid-tool** (66a2e1b0): `CancellationToken` por chamada interrompe `exec_shell` longo, não só o stream do provider.
- [x] **`build.ps1`** (82c9685d): script de build release para Windows PowerShell.

---
*Métricas coletadas em 2026-07-14: 18 crates, ~490k linhas Rust; testes: 629+ funções `#[test]` distribuídas no workspace; TODO/FIXME: apenas 25 (codebase disciplinado); CI: 18 workflows.*
