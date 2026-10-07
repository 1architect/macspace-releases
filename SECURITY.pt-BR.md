[English](SECURITY.md) · **Português** · [Español](SECURITY.es.md) · [Français](SECURITY.fr.md) · [Deutsch](SECURITY.de.md)

# Política de Segurança

O MacSpace é um app gratuito e de código aberto (MIT) para macOS. Ele roda com a sua conta de
usuário normal. Para as poucas tarefas que exigem um administrador, usa um auxiliar privilegiado
que você aprova uma vez. Ele não coleta nenhum dado sobre você. Este documento explica exatamente o
que o MacSpace toca no seu Mac e como relatar um problema.

## Como relatar uma vulnerabilidade

Use o relato privado de vulnerabilidades do GitHub:
[relatar uma vulnerabilidade](https://github.com/1architect/macspace-releases/security/advisories/new).
Ou escreva para **dev@giomantovani.com.br** com os detalhes e os passos para reproduzir. Por favor,
não abra uma issue pública para um relato de segurança. Você recebe uma confirmação em poucos dias.

O que conta: qualquer coisa que permita a outro programa fazer o auxiliar executar o que você não
pediu, que permita ao MacSpace apagar ou alterar algo que não deveria, ou que permita instalar uma
atualização sem a assinatura da versão.

## Versões com suporte

As correções de segurança entram só na versão mais recente. Atualize sempre para a versão mais nova
em [Releases](https://github.com/1architect/macspace-releases/releases/latest), com **Buscar
Atualizações…** ou com `brew upgrade --cask macspace` (acrescente `--greedy` se o Homebrew a
ignorar, porque o MacSpace se atualiza sozinho).

## O que o MacSpace faz no seu Mac

### Rede

O MacSpace faz conexões de rede para um único fim: atualizações. Quando você escolhe **Buscar
Atualizações…** (ou **Verificar Agora** nos Ajustes) e, se você ativou **Buscar atualizações
automaticamente**, cerca de uma vez por dia enquanto ele está aberto, ele lê o feed de atualizações
hospedado junto com as versões no GitHub (`appcast.xml`). Se você aceitar uma atualização, ele
baixa a nova versão do GitHub Releases. Nada é enviado sobre você, e o perfil de sistema opcional
do Sparkle não está ativado.

Não há análises de uso, telemetria nem relatório de falhas. Os detalhes estão na
[Política de Privacidade](PRIVACY.pt-BR.md).

### Onde ficam os seus dados

Tudo fica no seu Mac. Os arquivos do MacSpace estão em `~/Library/Application Support/MacSpace/`,
`~/Library/Logs/MacSpace/`, no arquivo de preferências `~/Library/Preferences/com.macspace.app.plist`
e, para o que o auxiliar grava, em `/Library/Application Support/MacSpace/`. A
[Política de Privacidade](PRIVACY.pt-BR.md) lista cada arquivo. Nada disso é enviado para lugar
nenhum.

### O que o MacSpace apaga

| O quê | Onde | Feito por |
|---|---|---|
| Caches de apps que estão fechados | A pasta de cache do sistema de cada usuário (`/var/folders/…/C`), exceto os caches da própria Apple. As pastas `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache` e `CachedData` dentro de um perfil Chromium ou Electron em `~/Library/Application Support`. | O app, como você |
| Relatórios de diagnóstico e de falhas com mais de 7 dias | `/Library/Logs/DiagnosticReports` e `~/Library/Logs/DiagnosticReports`. Um arquivo que você não pode apagar é ignorado. | O app, como você |
| Recursos do sistema sem uso, modelos do Apple Intelligence liberados, arquivos que os apps marcaram como removíveis | O próprio serviço de limpeza do macOS (CacheDelete). O MacSpace o aciona em um processo filho de vida curta, para que uma falha ali não derrube o app. | O macOS |
| Cópias locais de arquivos da nuvem | Uma pasta da nuvem por vez (`~/Library/CloudStorage/…` ou iCloud Drive). Somente arquivos que já foram enviados e não têm conflito. Os arquivos continuam na nuvem. | O app, como você |
| Histórico de versões de documentos | `/System/Volumes/Data/.DocumentRevisions-V100` | O auxiliar |
| Arquivos restantes de atualização do macOS | `/System/Volumes/Data/macOS Install Data`, somente se for mais antigo que o sistema instalado. A pasta `Locked Files` permanece. | O auxiliar |

Nada vai para o Lixo. Caches, recursos do sistema e arquivos removíveis são recriados ou baixados de
novo quando necessário, e as cópias da nuvem são baixadas de novo quando você abre o arquivo.
Relatórios, histórico de versões e restos de atualização não voltam. Cada um desses itens pede
confirmação antes, exceto o botão **Liberar** dos caches de um único app.

### O que o MacSpace altera (Debloat)

Cada alteração é gravada primeiro em um diário, para poder ser desfeita com **Ativar tudo** ou
ativando o recurso de novo.

| Interruptor | O que muda | Feito por |
|---|---|---|
| Anúncios personalizados | `com.apple.AdLib`, chave `allowApplePersonalizedAdvertising` | O app, como você |
| Melhorar Siri e Ditado | `com.apple.assistant.support`, chave `Siri Data Sharing Opt-In Status` | O app, como você |
| Aviso de relatório de falhas | Uma substituição do launchd para `com.apple.DiagnosticsReporter` e `com.apple.ReportGPURestart` | O app, como você |
| Compartilhar análises com a Apple (versões finais do macOS) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, chaves `AutoSubmit` e `ThirdPartyDataSubmit` | O auxiliar |
| Siri AI, Inteligência Visual, Indexação para busca generativa | Substituições de feature flags em `/Library/Preferences/FeatureFlags/Domain/` | O auxiliar |
| Rastreamento de travamentos (tailspin) | `tailspin disable` e, para desfazer, `tailspin enable` | O auxiliar |
| As políticas (seis; sete numa versão beta do macOS) | Um perfil de configuração, `com.macspace.policies` (veja abaixo) | Você o aprova nos Ajustes do Sistema |

Essas alterações continuam no lugar se você apagar o app sem ativar os recursos de novo.

### Apple Intelligence

O interruptor **Apple Intelligence** altera a chave `Session Language` em
`com.apple.assistant.backedup`, que é o idioma da Siri. Com o interruptor desativado, a Siri recebe
um idioma diferente do idioma do sistema, e a sua voz da Siri (`Output Voice`) fica como está. O MacSpace
salva os dois em `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` e os
restaura quando você ativa o Apple Intelligence de novo ou se a alteração não fizer efeito. Se o
macOS mantiver os modelos depois que o interruptor for desativado, o MacSpace pode definir o idioma
como o do sistema e depois voltar, o que leva cerca de um minuto, para fazer o macOS liberá-los.
Com a sincronização da Siri com o iCloud ativada, essas alterações também chegam aos seus outros
dispositivos na mesma Conta Apple. O MacSpace não consegue desativar essa sincronização. Ele diz
onde você pode fazer isso.

### Permissões

O macOS cuida de cada pedido, então o MacSpace nunca vê a sua senha.

| Permissão | Onde | Para que o MacSpace a usa |
|---|---|---|
| Acesso Total ao Disco | Ajustes do Sistema > Privacidade e Segurança | Medir pastas que o macOS protege e ler o estado do Apple Intelligence |
| Auxiliar privilegiado | Ajustes do Sistema > Geral > Itens de Início e Extensões | As operações abaixo |
| Perfil de configuração | Ajustes do Sistema > Geral > Gerenciamento de Dispositivo | Somente quando você desativa uma política do Debloat |
| Notificações | O macOS pergunta | Avisar você de que algo terminou |

### O auxiliar privilegiado

O auxiliar é um daemon de inicialização (launch daemon), `com.macspace.helper`, registrado no macOS
de dentro do app. O launchd o inicia quando o MacSpace pede alguma coisa. Ele roda como root e só
aceita uma conexão de um programa que satisfaça este requisito de assinatura de código, que o macOS
confere:

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

Ele se recusa a iniciar sem um requisito. Só executa operações nomeadas que estão embutidas nele.
Quem o chama não consegue enviar comandos a ele. Quando o app é substituído por uma atualização, o
auxiliar percebe e se encerra para que o novo comece.

| Operação | O que faz | Limites |
|---|---|---|
| `systemdata.measure` | Tamanhos de pastas | Somente leitura. Apenas em `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, na raiz do volume Data e em `/opt`, nunca em uma pasta pessoal. Tamanhos, nunca conteúdo. |
| `systemdata.versions.delete` | Apaga o histórico de versões de documentos | Primeiro para o `revisiond` ou, se o macOS recusar, o pausa. Apaga o conteúdo do armazenamento, não a pasta, e depois inicia o `revisiond` de novo. Se não conseguir pará-lo, não apaga nada. |
| `systemdata.staged-update.delete` | Apaga os arquivos restantes de atualização | Somente se a pasta for mais antiga que o sistema instalado. Mantém `Locked Files`. |
| `debloat.status`, `.apply`, `.revert` | Lê, desativa e ativa itens do Debloat | Somente identificadores de controle, do catálogo embutido. Nada além disso. |
| `debloat.removeProfile` | Remove um perfil do MacSpace | Somente os identificadores `com.macspace.policies` e `com.macspace.policies.…`. Qualquer outro perfil é recusado. |
| `siri.orphan-subscriptions.plan`, `.execute` | Encontra e remove as assinaturas do Apple Intelligence de contas que não existem mais | Antes faz backup do banco de dados em `/Library/Application Support/MacSpace/backups/`, altera-o em uma única transação, mexe apenas em linhas que não correspondem a nenhuma conta local e recusa se a lista de contas parecer errada. O app ainda não tem botão para isso. |
| `helper.ping` | Responde, para que o app saiba que o auxiliar está ativo | Nenhum |

A ferramenta de linha de comando do app, `MacSpaceCli`, dentro do pacote do app, também pode falar
com o auxiliar. Ela é assinada pela mesma equipe.

### O perfil de configuração

As políticas do Debloat são ajustes que só um perfil de configuração consegue impor. O MacSpace
monta um perfil, `com.macspace.policies` (exibido como **MacSpace: policies**, organização
"MacSpace"), com todas as políticas que você desativou. Ele abre o perfil, e você o aprova em
Ajustes do Sistema > Geral > Gerenciamento de Dispositivo. Aprová-lo substitui o anterior. Ele não
é marcado como impossível de remover. Ativar de novo a última política o remove, por meio do
auxiliar, sem nada para aprovar. Você também pode removê-lo por conta própria nos Ajustes do
Sistema.

### Assinatura de código e atualizações

O MacSpace é assinado com um Apple Developer ID, com o hardened runtime, e notarizado pela Apple. O
tíquete de notarização está anexado (stapled) ao app, então ele também abre sem conexão. Os
componentes do próprio Sparkle são assinados com a mesma identidade.

As atualizações também são assinadas com uma chave EdDSA. A metade pública dela está dentro do
MacSpace (`SUPublicEDKey`), e o Sparkle confere cada download com ela antes de instalar. A metade
privada dessa chave e a identidade de assinatura não estão neste repositório. Uma cópia do MacSpace
compilada sem a chave pública nunca busca atualizações.

## Verifique um download

Coloque `MacSpace-x.y.z.dmg` e `MacSpace-x.y.z.dmg.sha256` na mesma pasta:

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

Depois, quando você tiver arrastado o MacSpace para Aplicativos:

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

Você deve ver `Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, o sinalizador
`runtime` e `Notarization Ticket=stapled`, e o `spctl` deve dizer `accepted` com
`source=Notarized Developer ID`.

## Desinstalar por completo

Não há desinstalador no app. Os passos completos estão no
[README](README.pt-BR.md#desinstalar). Em resumo:

1. Em **Debloat**, clique em **Ativar tudo**. Isso remove as substituições e o perfil que ele criou.
2. Se o perfil **MacSpace: policies** ainda estiver em Ajustes do Sistema > Geral > Gerenciamento de
   Dispositivo, remova-o.
3. Encerre o MacSpace. Desative-o em Ajustes do Sistema > Geral > Itens de Início e Extensões ou
   execute `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`.
4. Remova o app: `brew uninstall --cask macspace` ou arraste o **MacSpace** para o Lixo.
5. Remova os dados e as preferências:
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. Remova o MacSpace de Ajustes do Sistema > Privacidade e Segurança > Acesso Total ao Disco.
