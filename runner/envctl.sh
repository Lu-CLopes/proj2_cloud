#!/bin/bash

# ---------
# envctl.sh 
# ---------

# Script utilizado para gerenciamento de ambientes de execução de processos, utilizando cgroups e namespaces.
# Não é necessário rodar comandos com sudo, pois o script já é rodado com privilégios de root.

CMD=$1
ID=$2

if [ "$#" -lt 2 ]; then
    echo "Uso: $0 <comando> <id> [<args>]"
    exit 1
fi

CG="/sys/fs/cgroup/proj2/env-$ID"
ENV_DIR="/var/lib/proj2/envs/$ID"

# ---------------------------------------------------------
# COMANDOS INTERNOS (não chamados pelo PHP)
# ---------------------------------------------------------
if [ "$CMD" == "_supervise" ]; then
    NET=$3
    mkdir -p /sys/fs/cgroup/proj2/supervisor
    echo "$$" > /sys/fs/cgroup/proj2/supervisor/cgroup.procs
    echo "$$" > "$ENV_DIR/supervisor.pid"

    (
        echo "$BASHPID" > "$CG/cgroup.procs"
        echo "$BASHPID" > "$ENV_DIR/main.pid"
        exec unshare --pid --fork --kill-child \
                     --mount --mount-proc \
                     --uts --ipc \
                     $( [ "$NET" = 1 ] && echo --net ) \
             -- /bin/bash /opt/proj2_cloud/runner/envctl.sh _inner "$ID" "$NET"
    ) >> "$ENV_DIR/output.log" 2>&1 &

    MAIN_PID=$!
    wait $MAIN_PID
    echo $? > "$ENV_DIR/exit_code"
    exit 0
fi

if [ "$CMD" == "_inner" ]; then
    NET=$3
    hostname "env-$ID"
    mount -t tmpfs -o size=64m,mode=1777 tmpfs /tmp
    [ "$NET" = 1 ] && ip link set lo up

    cd "$ENV_DIR/work"
    exec setpriv --reuid=proj2run --regid=proj2run --init-groups \
                 --inh-caps=-all --bounding-set=-all --no-new-privs \
         env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$ENV_DIR/work" \
                JOB_DIR="$ENV_DIR/job" ENV_ID="$ID" \
         /bin/bash "$ENV_DIR/job/run.sh"
    exit 0
fi

# ---------------------------------------------------------
# API EXTERNA (chamadas pelo PHP)
# ---------------------------------------------------------

# |----------|
# | 1) start |
# |----------|
if [ "$CMD" == "start" ]; then
    if [ "$#" -ne 7 ]; then
        echo "Falha ao iniciar: Número incorreto de argumentos"
        exit 1
    fi

    CPU=$3
    MEM=$4
    IO_R=$5
    IO_W=$6
    NET=$7

    # verificar valores
    if [ "$CPU" -lt 5 ] || [ "$CPU" -gt 100 ]; then echo "Falha ao iniciar: CPU % fora do limite, [5-100]"; exit 1; fi
    if [ "$MEM" -lt 16 ] || [ "$MEM" -gt 2048 ]; then echo "Falha ao iniciar: Memória MB fora do limite, [16-2048]"; exit 1; fi
    if [ "$NET" -ne 0 ] && [ "$NET" -ne 1 ]; then echo "Falha ao iniciar: Rede inválida, [0-1]"; exit 1; fi

    # preparar diretórios e copiar arquivos por segurança
    mkdir -p "$ENV_DIR/work" "$ENV_DIR/job" /sys/fs/cgroup/proj2
    chown -R proj2run:proj2run "$ENV_DIR/work"  # permite o usuário criar arquivos
    echo "+cpu +memory +io +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
    echo "+cpu +memory +io +pids" > /sys/fs/cgroup/proj2/cgroup.subtree_control 2>/dev/null
    cp -r "/var/lib/proj2/jobs/$ID/"* "$ENV_DIR/job/" 2>/dev/null
    chmod -R 755 "$ENV_DIR/job"
    touch "$ENV_DIR/output.log"
    chmod 0644 "$ENV_DIR/output.log"

    # criar cgroups e aplicar limites
    mkdir -p "$CG"
    echo "$((CPU * 1000)) 100000" > "$CG/cpu.max"
    echo "$((MEM * 1024 * 1024))" > "$CG/memory.max"
    echo 0 > "$CG/memory.swap.max"
    echo 512 > "$CG/pids.max"

    if [ "$IO_R" -gt 0 ] || [ "$IO_W" -gt 0 ]; then
        TARGET_MNT=$(findmnt -no SOURCE --target /var/lib/proj2)
        DISK_NAME=$(lsblk -no PKNAME "$TARGET_MNT" | head -n1)
        [ -z "$DISK_NAME" ] && DISK_NAME=$(basename "$TARGET_MNT" | head -n1)
        MAJMIN=$(lsblk -dno MAJ:MIN "/dev/$DISK_NAME" 2>/dev/null | head -n1)
        [ -z "$MAJMIN" ] && MAJMIN="8:0"

        [ "$IO_R" -eq 0 ] && R_LIMIT="max" || R_LIMIT=$((IO_R * 1024 * 1024))
        [ "$IO_W" -eq 0 ] && W_LIMIT="max" || W_LIMIT=$((IO_W * 1024 * 1024))

        echo "$MAJMIN rbps=$R_LIMIT wbps=$W_LIMIT" > "$CG/io.max" 2>/dev/null
    fi

    # iniciar Supervisor desacoplado do PHP e sudo
    setsid -f /opt/proj2_cloud/runner/envctl.sh _supervise "$ID" "$NET" >/dev/null 2>&1

    # aguardar até o processo isolado escrever o main.pid (até 5s)
    for i in {1..50}; do
        if [ -f "$ENV_DIR/main.pid" ]; then
            echo "started $(cat "$ENV_DIR/main.pid")"
            exit 0
        fi
        sleep 0.1
    done
    
    echo "Falha ao iniciar: timeout aguardando a criação do main.pid"
    exit 1

# |-----------|
# | 2) status |
# |-----------|
elif [ "$CMD" == "status" ]; then
    if [ ! -d "$ENV_DIR" ]; then
        echo "unknown"
        exit 0
    fi

    if [ -f "$ENV_DIR/exit_code" ]; then
        RC=$(cat "$ENV_DIR/exit_code")
        if [ -f "$ENV_DIR/stopped" ]; then
            echo "stopped $RC"
        else
            OOM=""
            if [ -f "$CG/memory.events" ]; then
                OOM_KILL=$(grep -E '^oom_kill ' "$CG/memory.events" | awk '{print $2}')
                if [ -n "$OOM_KILL" ] && [ "$OOM_KILL" -gt 0 ]; then OOM=" oom"; fi
            fi
            echo "exited $RC$OOM"
        fi
    elif [ -f "$ENV_DIR/supervisor.pid" ] && kill -0 $(cat "$ENV_DIR/supervisor.pid") 2>/dev/null; then
        if [ -f "$ENV_DIR/main.pid" ]; then echo "running $(cat "$ENV_DIR/main.pid")"
        else echo "running $(cat "$ENV_DIR/supervisor.pid")"; fi
    else
        echo "lost"
    fi
    exit 0

# |---------|
# | 3) stop |
# |---------|
elif [ "$CMD" == "stop" ]; then
    touch "$ENV_DIR/stopped" 2>/dev/null
    if [ -d "$CG" ]; then
        for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
        sleep 3
        echo 1 > "$CG/cgroup.kill" 2>/dev/null
    fi
    echo "stopped"
    exit 0

# |-----------|
# | 4) remove |
# |-----------|
elif [ "$CMD" == "remove" ]; then
    /opt/proj2_cloud/runner/envctl.sh stop "$ID" >/dev/null 2>&1
    sleep 1
    if [ -d "$CG" ]; then rmdir "$CG" 2>/dev/null; fi
    
    rm -rf "/var/lib/proj2/envs/$ID"
    rm -rf "/var/lib/proj2/jobs/$ID"

    echo "removed"
    exit 0

# |---------|
# | 5) info |
# |---------|
elif [ "$CMD" == "info" ]; then
    if [ ! -d "${CG}" ]; then
        echo "Erro: O cgroup do ambiente $ID não existe"
        exit 1
    fi
    echo "cpu.max=$(cat "$CG/cpu.max" 2>/dev/null)"
    echo "memory.current=$(cat "$CG/memory.current" 2>/dev/null)"
    echo "memory.max=$(cat "$CG/memory.max" 2>/dev/null)"
    echo "pids.current=$(cat "$CG/pids.current" 2>/dev/null)"
    echo "ns.pid=pid:[$(cat "$CG/cgroup.procs" 2>/dev/null | tr '\n' ',' | sed 's/,$//')]"
    exit 0

else
    echo "Erro: Comando inválido. Use start, status, stop, remove ou info."
    exit 1
fi