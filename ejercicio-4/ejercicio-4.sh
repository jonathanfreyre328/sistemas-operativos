#!/usr/bin/env bash

set -o pipefail

declare -r DIRECTORIO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r ARCHIVO_BD="$DIRECTORIO_SCRIPT/data.sq3"
declare -r ARCHIVO_LOG="$DIRECTORIO_SCRIPT/system.log"
declare -r ARCHIVO_LOG_ERRORES="$DIRECTORIO_SCRIPT/error.log"
declare -r ARCHIVO_REPORTE="$DIRECTORIO_SCRIPT/productos.html"

declare USUARIO_ID=""
declare USUARIO_ACTUAL=""

# Funciones de envoltura para whiptail
wt_msg() { whiptail --title "$1" --msgbox "$2" 10 60; }
wt_input() { whiptail --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3; }
wt_pass() { whiptail --title "$1" --passwordbox "$2" 10 60 3>&1 1>&2 2>&3; }

registrar_error() {
    local mensaje="$1"
    printf "%s\t%s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$ARCHIVO_LOG_ERRORES"
}

registrar_accion() {
    local accion="$1"
    printf "%s\t%s\t%s\t%s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${USUARIO_ID:--}" \
        "${USUARIO_ACTUAL:--}" \
        "$accion" >> "$ARCHIVO_LOG"
}

sql_escape() {
    local valor="$1"
    valor=${valor//\'/\'\'}
    printf "%s" "$valor"
}

ejecutar_sql() {
    local consulta="$1"
    local resultado

    resultado=$(sqlite3 -batch "$ARCHIVO_BD" "$consulta" 2>&1)
    local estado=$?
    if (( estado != 0 )); then
        registrar_error "Error SQLite: $resultado"
        return "$estado"
    fi
    printf "%s" "$resultado"
}

inicializar_base_datos() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        registrar_error "SQLite3 no está instalado."
        printf "Error: SQLite3 no está instalado.\n" >&2
        return 1
    fi

    if ! command -v whiptail >/dev/null 2>&1; then
        registrar_error "whiptail no está instalado."
        printf "Error: whiptail no está instalado.\n" >&2
        return 1
    fi

    if [[ ! -f "$ARCHIVO_BD" ]]; then
        if ! sqlite3 "$ARCHIVO_BD" <<'SQL'
CREATE TABLE usuarios (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL
);
CREATE TABLE productos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    nombre TEXT NOT NULL,
    precio REAL NOT NULL
);
SQL
        then
            registrar_error "No se pudo crear la base de datos."
            return 1
        fi
    fi

    touch "$ARCHIVO_LOG" 2>/dev/null || {
        registrar_error "No se pudo inicializar el archivo de log del sistema."
        return 1
    }
    touch "$ARCHIVO_LOG_ERRORES" 2>/dev/null || {
        printf "Error: no se pudo abrir el log de errores.\n" >&2
        return 1
    }
}

obtener_hash() {
    printf "%s" "$1" | sha256sum | cut -d' ' -f1
}

existe_usuario() {
    local usuario
    usuario=$(sql_escape "$1")
    [[ -n "$(ejecutar_sql "SELECT 1 FROM usuarios WHERE username = '$usuario' LIMIT 1;")" ]]
}

existe_producto() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$(ejecutar_sql "SELECT 1 FROM productos WHERE id = $1 LIMIT 1;")" ]]
}

registrar_usuario() {
    local user pass hash user_sql
    user=$(wt_input "Registro de Usuario" "Ingrese nuevo nombre de usuario:")
    [[ $? -ne 0 ]] && return

    if [[ -z "$user" ]]; then
        wt_msg "Error" "El usuario no puede estar vacío."
        registrar_error "El usuario no puede estar vacío."
        return
    fi

    if existe_usuario "$user"; then
        wt_msg "Error" "El usuario '$user' ya existe."
        registrar_error "El usuario '$user' ya existe."
        return
    fi

    pass=$(wt_pass "Registro de Usuario" "Ingrese contraseña:")
    [[ $? -ne 0 ]] && return

    if [[ -z "$pass" ]]; then
        wt_msg "Error" "La contraseña no puede estar vacía."
        registrar_error "La contraseña no puede estar vacía."
        return
    fi

    hash=$(obtener_hash "$pass")
    user_sql=$(sql_escape "$user")
    if ejecutar_sql "INSERT INTO usuarios (username, password_hash) VALUES ('$user_sql', '$hash');" >/dev/null; then
        wt_msg "Éxito" "Usuario '$user' registrado exitosamente."
    else
        wt_msg "Error" "No se pudo registrar el usuario."
    fi
}

iniciar_sesion() {
    local user pass hash datos user_sql
    local intentos=0

    if [[ -z "$(ejecutar_sql "SELECT 1 FROM usuarios LIMIT 1;")" ]]; then
        wt_msg "Información" "No hay usuarios registrados en el sistema. Registre uno primero."
        registrar_error "No hay usuarios registrados en el sistema. Registre uno primero."
        return 1
    fi

    while (( intentos < 3 )); do
        user=$(wt_input "Inicio de Sesión" "Usuario:")
        [[ $? -ne 0 ]] && return 1
        
        pass=$(wt_pass "Inicio de Sesión" "Contraseña:")
        [[ $? -ne 0 ]] && return 1

        hash=$(obtener_hash "$pass")
        user_sql=$(sql_escape "$user")
        datos=$(ejecutar_sql "SELECT id || char(9) || username FROM usuarios WHERE username = '$user_sql' AND password_hash = '$hash' LIMIT 1;")

        if [[ -n "$datos" ]]; then
            IFS=$'\t' read -r USUARIO_ID USUARIO_ACTUAL <<< "$datos"
            wt_msg "Bienvenido" "Acceso concedido. Bienvenido/a, $USUARIO_ACTUAL."
            return 0
        fi

        intentos=$((intentos + 1))
        wt_msg "Error" "Credenciales incorrectas ($intentos/3 intentos)."
    done

    registrar_error "Inicio de sesión fallido: se agotaron los intentos."
    return 1
}

alta_producto() {
    local nombre precio nombre_sql id
    nombre=$(wt_input "Alta de Producto" "Ingrese Nombre del producto:")
    [[ $? -ne 0 ]] && return
    
    precio=$(wt_input "Alta de Producto" "Ingrese Precio del producto:")
    [[ $? -ne 0 ]] && return

    if [[ -z "$nombre" || -z "$precio" ]]; then
        wt_msg "Error" "El nombre y el precio son obligatorios."
        registrar_error "El nombre y el precio son obligatorios."
        return
    fi
    if [[ ! "$precio" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        wt_msg "Error" "El precio debe ser numérico."
        registrar_error "El precio '$precio' no es numérico."
        return
    fi

    nombre_sql=$(sql_escape "$nombre")
    id=$(ejecutar_sql "INSERT INTO productos (nombre, precio) VALUES ('$nombre_sql', $precio); SELECT last_insert_rowid();")
    if [[ -n "$id" ]]; then
        wt_msg "Éxito" "Producto '$nombre' guardado correctamente con ID $id."
    else
        wt_msg "Error" "No se pudo guardar el producto."
    fi
}

baja_producto() {
    local id
    id=$(wt_input "Baja de Producto" "Ingrese ID del producto a eliminar:")
    [[ $? -ne 0 ]] && return

    if ! existe_producto "$id"; then
        wt_msg "Error" "No se encontró un producto con el ID '$id'."
        registrar_error "No se encontró un producto con el ID '$id'."
        return
    fi

    if ejecutar_sql "DELETE FROM productos WHERE id = $id;" >/dev/null; then
        wt_msg "Éxito" "Producto con ID '$id' eliminado correctamente."
    else
        wt_msg "Error" "No se pudo eliminar el producto."
    fi
}

modificar_producto() {
    local id nuevo_nombre nuevo_precio actual nombre_actual precio_actual nombre_sql
    id=$(wt_input "Modificar Producto" "Ingrese ID del producto a modificar:")
    [[ $? -ne 0 ]] && return

    if ! existe_producto "$id"; then
        wt_msg "Error" "No se encontró un producto con el ID '$id'."
        registrar_error "No se encontró un producto con el ID '$id'."
        return
    fi

    actual=$(ejecutar_sql "SELECT nombre || char(9) || precio FROM productos WHERE id = $id;")
    IFS=$'\t' read -r nombre_actual precio_actual <<< "$actual"
    
    nuevo_nombre=$(wt_input "Modificar Producto" "Nuevo Nombre (ID $id):" "$nombre_actual")
    [[ $? -ne 0 ]] && return
    
    nuevo_precio=$(wt_input "Modificar Producto" "Nuevo Precio (ID $id):" "$precio_actual")
    [[ $? -ne 0 ]] && return

    [[ -z "$nuevo_nombre" ]] && nuevo_nombre="$nombre_actual"
    [[ -z "$nuevo_precio" ]] && nuevo_precio="$precio_actual"

    if [[ ! "$nuevo_precio" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        wt_msg "Error" "El precio debe ser numérico."
        registrar_error "El precio '$nuevo_precio' no es numérico."
        return
    fi

    nombre_sql=$(sql_escape "$nuevo_nombre")
    if ejecutar_sql "UPDATE productos SET nombre = '$nombre_sql', precio = $nuevo_precio WHERE id = $id;" >/dev/null; then
        wt_msg "Éxito" "Producto ID '$id' modificado correctamente."
    else
        wt_msg "Error" "No se pudo modificar el producto."
    fi
}

mostrar_productos() {
    local filas tmp_file
    filas=$(ejecutar_sql "SELECT id || char(9) || nombre || char(9) || printf('%.2f', precio) FROM productos ORDER BY id;")
    if [[ -z "$filas" ]]; then
        wt_msg "Inventario" "El inventario está vacío."
        return
    fi

    tmp_file=$(mktemp)
    {
        printf "%-10s | %-20s | %-10s\n" "ID" "NOMBRE" "PRECIO"
        printf "%s\n" "..........................................."
        while IFS=$'\t' read -r id nombre precio; do
            printf "%-10s | %-20s | $%-9.2f\n" "$id" "$nombre" "$precio"
        done <<< "$filas"
    } > "$tmp_file"

    whiptail --title "Listado de Productos" --textbox "$tmp_file" 20 60
    rm -f "$tmp_file"
}

generar_reporte_html() {
    local filas
    filas=$(ejecutar_sql "SELECT id || char(9) || nombre || char(9) || printf('%.2f', precio) FROM productos ORDER BY id;")
    {
        echo "<!DOCTYPE html>"
        echo "<html lang=\"es\"><head><meta charset=\"UTF-8\"><title>Reporte de Productos</title>"
        echo "<style>body { font-family: Arial, sans-serif; margin: 20px; } table { border-collapse: collapse; width: 100%; max-width: 600px; } th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; } th { background-color: #f2f2f2; }</style>"
        echo "</head><body><h2>Reporte Detallado de Productos</h2><table><thead><tr><th>ID</th><th>Nombre</th><th>Precio</th></tr></thead><tbody>"
        while IFS=$'\t' read -r id nombre precio; do
            [[ -n "$id" ]] && printf "<tr><td>%s</td><td>%s</td><td>$%s</td></tr>\n" "$id" "$nombre" "$precio"
        done <<< "$filas"
        echo "</tbody></table></body></html>"
    } > "$ARCHIVO_REPORTE" || {
        registrar_error "No se pudo generar el reporte HTML."
        wt_msg "Error" "No se pudo generar el reporte HTML."
        return
    }
    wt_msg "Éxito" "Reporte HTML generado exitosamente en 'productos.html'."
}

flujo_principal() {
    local opcion=""
    local autenticado=0

    while (( autenticado == 0 )); do
        opcion=$(whiptail --title "Autenticación" --menu "Seleccione una opción:" 15 60 4 \
            "1" "Iniciar sesión" \
            "2" "Registrar usuario" \
            "3" "Salir" 3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && opcion="3"
        
        registrar_accion "Autenticacion: opcion $opcion"
        case $opcion in
            1) iniciar_sesion && autenticado=1 ;;
            2) registrar_usuario ;;
            3) return ;;
            *) wt_msg "Error" "Opción inválida." ;;
        esac
    done

    while true; do
        opcion=$(whiptail --title "Menú de Acciones - $USUARIO_ACTUAL" --menu "Seleccione una opción:" 16 60 6 \
            "1" "Alta producto" \
            "2" "Baja producto" \
            "3" "Modificar producto" \
            "4" "Mostrar inventario" \
            "5" "Generar reporte HTML" \
            "6" "Salir" 3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && break

        registrar_accion "Menu de acciones: opcion $opcion"
        case $opcion in
            1) alta_producto ;;
            2) baja_producto ;;
            3) modificar_producto ;;
            4) mostrar_productos ;;
            5) generar_reporte_html ;;
            6) break ;;
            *) wt_msg "Error" "Opción inválida." ;;
        esac
    done
}

main() {
    inicializar_base_datos || exit 1
    flujo_principal
    clear
}

main "$@"