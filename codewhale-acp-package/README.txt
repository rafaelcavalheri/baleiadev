CodeWhale ACP (com suporte a tools: read/write/list/apply_patch/shell) - build local
=====================================================================================

Conteudo:
  codewhale.exe        - dispatcher (o que voce chama)
  codewhale-tui.exe     - motor real (precisa ficar do lado do codewhale.exe)

Requisitos na maquina de destino:
  - Windows x64 (mesma arquitetura deste build)
  - Nao precisa ter Rust nem o codigo-fonte instalado

Instalacao:
  1. Copie esta pasta inteira (ou so os dois .exe, mas MANTENHA os dois juntos
     na mesma pasta) para qualquer lugar na outra maquina.
     Ex: C:\Ferramentas\codewhale\

  2. Configure o Zed (arquivo settings.json, geralmente em
     %APPDATA%\Zed\settings.json) adicionando/editando:

     "agent_servers": {
       "CodeWhale": {
         "type": "custom",
         "command": "C:\\Ferramentas\\codewhale\\codewhale.exe",
         "args": ["serve", "--acp"]
       }
     }

     (ajuste o caminho para onde voce colocou os .exe)

  3. Configure a chave de API do DeepSeek nessa maquina (uma vez so):
     C:\Ferramentas\codewhale\codewhale.exe auth set --provider deepseek
     (ou copie o arquivo %USERPROFILE%\.codewhale\config.toml + secrets da
     maquina original, se preferir nao digitar a chave de novo)

  4. Reinicie o Zed, abra uma pasta de projeto, selecione o agente "CodeWhale"
     no painel de Agent, e teste um prompt como:
     "Leia o Cargo.toml e me diga a versao do projeto"

Verificar se esta usando o DeepSeek:
  codewhale.exe auth list
  echo {"jsonrpc":"2.0","id":1,"method":"session/currentModel","params":{}} | codewhale.exe serve --acp

Origem deste build:
  Branch feature/acp-filesystem-tools do fork
  https://github.com/rafaelcavalheri/baleiadev
  (ainda nao mesclado no repositorio original Hmbown/CodeWhale)
