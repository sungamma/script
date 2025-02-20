#!/bin/bash

last_check_time=0
counter=0

# 创建命名管道，确保目录可写
PIPE_PATH="/tmp/ffmpeg_pipe_$$"  # 使用临时路径，避免冲突
mkfifo "$PIPE_PATH"

# 启动ffmpeg7，输出到命名管道，并获取PID
/usr/local/bin/ffmpeg7 -i input.mp4 -c:v libx265 -c:a copy -crf 23 -preset medium out.mp4 -y -progress pipe:1 >"$PIPE_PATH" 2>&1 &
FFMPEG_PID=$!

# 从命名管道读取输出
while IFS= read -r line; do
    echo "test: $line"
    if [[ "$line" =~ speed=(([0-9.]+)x?|N/A) ]]; then
        speed_raw="${BASH_REMATCH[1]}"
        speed="${speed_raw/x/}"
        if [[ "$speed" == "N/A" ]]; then
            speed=0
        fi
        echo "当前速度为: $speed"
        current_time=$(date +%s)
        if ((current_time - last_check_time >= 1)); then
            echo "低速计数 $speed"
            if awk -v spd="$speed" 'BEGIN { exit (spd < 2) ? 0 : 1 }'; then
                ((counter++))
                echo "当前速度为: $speed, 低速计数：$counter/3"
                if ((counter >= 3)); then
                    echo "[警告] 连续三次低速，终止进程"
                    kill -9 "$FFMPEG_PID" 2>/dev/null  # 强制终止
                    rm -f "$PIPE_PATH"
                    exit 1
                fi
            else
                counter=0
            fi
            last_check_time=$current_time
        fi
    fi
done <"$PIPE_PATH"

# 清理
rm -f "$PIPE_PATH"