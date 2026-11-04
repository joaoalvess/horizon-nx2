# Goal text

Paste this text after `/goal ` in a Claude Code session opened in `~/Developer/switch`, with auto mode on. The condition is under 4,000 characters.

```
Trabalho do refactor em ~/Developer/switch, sem o usuário, até as 13:00 de 2026-11-04. Fonte de verdade: agents/refactor/. Leia agents/refactor/README.md, rules.md, plan.md e night-2026-11-04.md antes de começar, e de novo depois de cada compactação de contexto. night-2026-11-04.md é o plano que o usuário pediu para executar, e os commits locais que ele lista estão pedidos. Execute-o e avance o quanto der, em ordem:
- setup na main;
- Track A (S0: capturas do Pokopia e do DK com os binários base) num subagente de captura;
- Track B na branch refactor: S1, S2, S2b, HT (as threads do host), S3a, S3b e seguintes, um item por vez. Cada estágio só começa quando o anterior cumpre o critério dele no plan.md; o que não depende de um estágio travado segue;
- Track C (agents/architecture/: três subagentes de arquitetura em paralelo, depois um revisor);
- medição antes de cada resumo.
Fora do escopo: capturas do MKW. Antes do setup, confira em pmset -g batt que o Mac está na tomada.

Como trabalhar: você orquestra e mantém só o estado e as conclusões. Briefe cada subagente apontando o arquivo do papel em agents/refactor/roles/ e o item; não redigite o papel. Cada item passa por um implementador (um por vez: mesma árvore, sem worktree) e por um revisor independente, que não vê o raciocínio do implementador. Só depois você comita, junto com a linha State do catalog.md. Use subagentes de busca para chamadores, causas de falha e frames. Antes de cada resumo, um subagente revisa o diff inteiro <BASE>..refactor. Cada arquivo tem um único escritor (agents/refactor/README.md); subagentes escrevem só o próprio relatório em agents/refactor/reports/.

Regras (detalhe em rules.md):
- Boot só pelo guard.py, um por vez, em background (run_in_background), nunca matando o guard. Abaixo de 30% de memória livre, espere.
- STOP_<jogo> ou STOP_ALL param os boots daquele jogo ou de todos.
- Nunca use os saves reais (run/save do usuário, saves/esposa): sempre uma cópia nova.
- Commits locais em inglês, sem push, sem Co-Authored-By nem atribuição, só os arquivos do item. Nunca comite docs/env_switches.tsv, PERF_M4.md, POKOPIA.md nem STREAMING.md.
- Nunca: push, assinatura, eas, deploy, reboot, reset, clean, force, worktree. Item que falha antes do commit sai como rules.md manda (patch salvo, depois git checkout dos arquivos dele); depois do commit, com git revert.
- Ache a causa raiz antes de mudar código. Diff mínimo e sem comentários.
- Não pergunte nada ao usuário: o que for decisão dele vai para Open no arquivo da noite, e você segue.
- Não termine um turno sem chamar ferramenta enquanto houver trabalho. Esperando algo em background, faça trabalho offline.
- Imprima `date` a cada marco.

Resumos: um parcial quando `date` mostrar 2026-11-04 08:00 ou mais, e o final às 13:00 (antes, se nada mais puder avançar sem o usuário). Os dois vão para o terminal e para night-2026-11-04.md.

Condição de término: o goal está cumprido quando você tiver impresso no terminal o resumo final, também escrito em night-2026-11-04.md, contendo:
(1) BASE;
(2) as capturas mantidas por jogo, com o ruído medido (pelo menos 5 por jogo para Pokopia e DK, ou o motivo de faltar);
(3) o resultado do S1: hash do commit, ou o motivo de não haver commit, com testes e replays;
(4) cada item de S2, S2b e HT como commitado (hash), revertido (motivo) ou não alcançado, e até onde o S3 chegou;
(5) a CPU de replay base x HEAD e o bench do DK, ou o motivo de faltar;
(6) o veredito da revisão final do diff, ou o motivo de faltar;
(7) os arquivos de agents/architecture/ escritos, com o veredito do revisor (ou o motivo de faltar algum);
(8) a lista Open.
O goal só pode ser dado como cumprido se o `date` impresso mostrar 2026-11-04 13:00 ou mais tarde, ou se o resumo disser por que nada mais pode avançar sem o usuário.
```
