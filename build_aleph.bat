@echo off
chcp 65001 > nul
echo ============================================
echo  ALEPH ENGINE - Build + ccache
echo ============================================

:: Añadir ccache al PATH (ubicado junto a este script)
set "ENGINE_DIR=%~dp0engine"
set "PATH=%PATH%;%ENGINE_DIR%"

:: Verificar ccache
ccache --version > nul 2>&1
if errorlevel 1 (
    echo [ERROR] ccache no encontrado en %ENGINE_DIR%
    echo Descargar de: https://github.com/ccache/ccache/releases
    exit /b 1
)

:: ============================================
:: LIMPIEZA DE PROCESOS COMPILADOR
:: ============================================
echo [INFO] Limpiando procesos del compilador...
:: NOTA: NUNCA matar python.exe - el MCP de Godot corre en Python
taskkill /F /IM cl.exe 2> nul
taskkill /F /IM link.exe 2> nul

if exist "%ENGINE_DIR%\.sconsign.dblite" (
    echo [CLEAN] Eliminando .sconsign.dblite...
    del /Q "%ENGINE_DIR%\.sconsign.dblite"
)

if exist "%ENGINE_DIR%\.scons_cache" (
    echo [CLEAN] Eliminando .scons_cache...
    rmdir /S /Q "%ENGINE_DIR%\.scons_cache"
)

echo [INFO] Limpieza completada.
echo.

:: ============================================
:: CONFIGURAR CCACHE
:: ============================================
set CCACHE_DIR=%ENGINE_DIR%\.ccache
set CCACHE_MAXSIZE=10G
set CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime

:: Crear directorio de cache si no existe
if not exist "%CCACHE_DIR%" mkdir "%CCACHE_DIR%"

:: Configurar log del build
set "BUILD_LOG=%ENGINE_DIR%\build.log"

echo [INFO] Cache directory: %CCACHE_DIR%
echo [INFO] Log: %BUILD_LOG%
echo [INFO] Jobs: 2
echo.

:: Header del log
echo ============================================ > "%BUILD_LOG%"
echo  ALEPH ENGINE BUILD LOG >> "%BUILD_LOG%"
echo  Fecha: %date% %time% >> "%BUILD_LOG%"
echo  Jobs: 2 >> "%BUILD_LOG%"
echo ============================================ >> "%BUILD_LOG%"
echo. >> "%BUILD_LOG%"

ccache -s
echo.

:: ============================================
:: BUILD
:: ============================================
echo [BUILD] Iniciando compilacion con ccache...
echo [BUILD] Target: editor, Jobs: 2
echo.

cd /d "%ENGINE_DIR%"
py -m SCons platform=windows target=editor -j2 >> "%BUILD_LOG%" 2>&1

:: ============================================
:: RESULTADO
:: ============================================
if %ERRORLEVEL% == 0 (
    echo.
    echo ============================================
    echo  BUILD EXITOSO
    echo ============================================
    echo.
    if exist "bin\godot.windows.editor.x86_64.exe" (
        for %%I in ("bin\godot.windows.editor.x86_64.exe") do (
            echo Tamano: %%~zI bytes
            echo Fecha: %%~tI
        )
    )
) else (
    echo.
    echo ============================================
    echo  BUILD FALLIDO
    echo ============================================
    echo Codigo de error: %ERRORLEVEL%
    echo.
    echo Ultimas 30 lineas del log:
    echo ----------------------------------------
    type "%BUILD_LOG%" 2>nul | findstr /n "." | findstr "^...[2-9][0-9]:" 2>nul
    if %ERRORLEVEL% neq 0 type "%BUILD_LOG%" 2>nul
)

echo.
ccache -s
echo.
pause
