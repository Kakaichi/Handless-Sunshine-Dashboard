# Handless Sunshine Dashboard (PySide6)

Interface gráfica para o mesmo conjunto de ações do `../sunshine/gerenciar-servicos.bat`.

Documentação completa na [README da raiz](../README.md).

Versão atual: edite `VERSION` (semver). O build copia esse arquivo para `dist/HeadlessSteam/VERSION`.

## Desenvolvimento

```powershell
cd headless-steam-app
pip install -r requirements.txt
python main.py
```

**Requisito:** execute como administrador (UAC).

## Build

```powershell
.\build.ps1
```

Saída: `dist/HandlessSteam/HandlessSteam.exe` — nome de exibição: **Handless Sunshine Dashboard** + versão.
