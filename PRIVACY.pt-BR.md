[English](PRIVACY.md) · **Português** · [Español](PRIVACY.es.md) · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md)

# Política de Privacidade — MacSpace

**Última atualização: 6 de outubro de 2026 · Vale para o MacSpace 1.0.0 em diante**

O MacSpace não coleta, não armazena e não transmite nenhum dado de uso. Não há análises de uso,
telemetria, relatório de falhas nem publicidade. O MacSpace não tem sistema de contas: você nunca
cria um perfil nem inicia sessão.

Este documento descreve exatamente o que o MacSpace lê, onde ele guarda e o único momento em que
ele usa a rede.

---

## O que fica no seu Mac

O MacSpace mede o seu disco, lê alguns ajustes do sistema e grava alguns arquivos pequenos na sua
própria máquina. Nada disso sai do seu Mac.

| Dado | Onde fica guardado |
|---|---|
| Seus ajustes: tema, escolhas da janela, quais módulos estão ativados, opções dos módulos, limpeza automática, escolhas de notificação, o último bloco que cada módulo mostrou, a etapa da primeira abertura | Preferências do macOS (`UserDefaults`) do MacSpace, `~/Library/Preferences/com.macspace.app.plist` |
| Os ajustes do próprio Sparkle: se ele busca atualizações automaticamente e quando buscou pela última vez | O mesmo arquivo de preferências |
| Histórico de limpezas: quando, qual módulo, quanto liberou, como começou, um resumo de uma linha | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| Espaço que o macOS manteve embora o MacSpace tenha pedido que o liberasse | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Diário do Debloat: cada ajuste que o MacSpace alterou, o valor antes e depois, a versão (build) do macOS e quando | `~/Library/Application Support/MacSpace/debloat-journal.json` e, para as alterações feitas pelo auxiliar, `/Library/Application Support/MacSpace/debloat-journal.json` |
| Monitoramento do Debloat: quais recursos o macOS reativou e quando (os últimos 20 eventos) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| O perfil do Debloat, como ele fica preparado para a sua aprovação | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| O idioma e a voz da sua Siri, salvos enquanto o Apple Intelligence está desativado para que o MacSpace possa restaurá-los | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Monitoramento do Apple Intelligence (só se você o ativar): o último estado que ele viu e um registro das mudanças | `~/Library/Application Support/MacSpace/ai-watch-state.json` e `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| Um backup do banco de dados de assinaturas do macOS, só se você remover assinaturas restantes do Apple Intelligence de contas apagadas | `/Library/Application Support/MacSpace/backups/` |
| Downloads de atualizações | A pasta de cache do Sparkle, `~/Library/Caches/com.macspace.app/` |

Você pode apagar tudo isso quando quiser. O [README.pt-BR.md](README.pt-BR.md#desinstalar) lista os
comandos. Apagar esses arquivos faz o MacSpace esquecer o histórico e os ajustes. Se você apagar os
diários do Debloat enquanto houver recursos do Debloat desativados, o MacSpace não consegue mais
restaurar os valores originais que salvou e passa a usar os padrões do macOS. Clique em **Ativar
tudo** antes.

### O que o MacSpace lê

O MacSpace lê estas coisas no seu Mac, para fazer o seu trabalho. Ele não envia nenhuma delas para
lugar nenhum.

- **Nomes e tamanhos de arquivos e pastas**, no disco inteiro depois que você concede o Acesso
  Total ao Disco. Ele não lê o que há nos seus documentos, fotos, e-mails ou mensagens. Ele mede
  quanto espaço eles ocupam.
- **Alguns arquivos do sistema:** o arquivo de elegibilidade do Apple Intelligence, o banco de
  dados de assinaturas de recursos do macOS, a lista de perfis de configuração instalados e o banco
  de dados da Conta Apple (somente leitura, para saber se a sincronização da Siri com o iCloud está
  ativada).
- **Os nomes das contas de usuário deste Mac**, para dizer qual conta mantém o Apple Intelligence
  ativado.
- **O estado do macOS:** a versão e o build, se a Proteção de Integridade do Sistema está ativada,
  se o Mac está inscrito em gerenciamento de dispositivo, os nomes dos processos em execução (para
  conferir se um interruptor do Debloat fez efeito) e algumas linhas do registro do sistema que
  anotam as decisões de análise do próprio macOS (para conferir se o interruptor de análises
  funcionou).

---

## Quando o MacSpace usa a rede

O MacSpace usa a rede para um único fim: **atualizações**. Ele não tem análises de uso, início de
sessão nem outra conexão.

### Quando ele busca atualizações

O MacSpace usa o [Sparkle](https://sparkle-project.org) para encontrar e instalar atualizações. Ele
acessa a rede nestes casos:

- quando você escolhe **Buscar Atualizações…** no menu MacSpace ou **Verificar Agora** nos Ajustes;
- cerca de uma vez por dia enquanto o MacSpace está aberto, se a busca automática estiver ativada.

A busca automática fica desativada até você ativar **Buscar atualizações automaticamente** nos
Ajustes ou responder sim à pergunta que o Sparkle faz uma vez, a partir da segunda abertura. Até
lá, o MacSpace não busca nada sozinho. Uma versão que você compila a partir do código-fonte não tem
chave de atualização e nunca busca nada.

Uma busca pede um arquivo ao GitHub:

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

Como em qualquer requisição web, o GitHub pode ver o seu endereço IP. A requisição também leva o
nome e a versão do MacSpace e a versão do Sparkle, no cabeçalho `User-Agent` habitual. O MacSpace
não envia perfil de sistema, informação de hardware nem identificador de espécie alguma. O perfil
de sistema opcional do Sparkle não está ativado. O tratamento que o GitHub dá a essa requisição
está na
[Declaração de Privacidade do GitHub](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement).

Se você aceitar uma atualização, o Sparkle a baixa do GitHub Releases. Toda atualização é assinada.
O Sparkle confere a assinatura com a chave pública que está dentro do MacSpace antes de instalar
qualquer coisa.

### O que não é o MacSpace

Se você ativar o Apple Intelligence de novo, o macOS (não o MacSpace) pode baixar os modelos dele.
Quando você abre um app baixado, o macOS pode conferi-lo com a Apple. Essas são conexões do próprio
macOS.

---

## O que o MacSpace nunca faz

- Nunca envia a sua lista de arquivos, os números do seu disco, os seus ajustes, o histórico de
  limpezas nem os nomes das contas para lugar nenhum.
- Nunca lê o conteúdo dos seus documentos, fotos, e-mails ou mensagens.
- Nunca pede que você crie uma conta nem que inicie sessão.
- Nunca relata falhas nem uso, nem ao desenvolvedor nem a ninguém.

### Sobre as permissões e o auxiliar

O MacSpace pede algumas aprovações, cada uma na janela do próprio macOS ou nos Ajustes do Sistema,
então ele nunca vê a sua senha:

- **Acesso Total ao Disco**, para medir tudo no disco e ler o estado do Apple Intelligence.
- **Um auxiliar privilegiado**, um daemon de inicialização (`com.macspace.helper`) que faz as
  poucas tarefas que exigem um administrador. Ele só aceita clientes assinados pela mesma equipe de
  desenvolvimento do MacSpace e só executa operações que estão embutidas nele.
- **Um perfil de configuração**, somente se você desativar uma política do Debloat.
- **Notificações**, para avisar você quando algo terminou.

O que o auxiliar e o perfil podem fazer está listado em [SECURITY.pt-BR.md](SECURITY.pt-BR.md).

---

## Crianças

O MacSpace é um utilitário para macOS e não se destina a crianças. Ele não coleta informação
pessoal de ninguém, de nenhuma idade.

## Mudanças nesta política

Se o comportamento do MacSpace mudar, este documento muda junto, e a data no topo muda também. O
histórico deste arquivo é público neste repositório: dá para ver exatamente o que mudou e quando.

## Contato

Dúvidas sobre privacidade, ou sobre qualquer ponto deste documento:

**dev@giomantovani.com.br**
