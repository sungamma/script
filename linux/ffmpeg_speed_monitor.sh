#!/bin/bash

# 群晖专用：无临时文件版低速自动终止脚本
# 初始化变量
last_check_time=0
counter=0

# 启动 ffmpeg7 并通过进程替换捕获输出（无临时文件）
exec 3< <("$FFMPEG_PATH" -i "$INPUT_VIDEO" -c:v libx265 -c:a copy -crf 23 -preset medium "$OUTPUT_VIDEO" -y -progress pipe:1 2>&1)
FFMPEG_PID=$!

# 从文件描述符 3 读取输出并监控速度
while IFS= read -r line; do
    echo "test: $line"
    if [[ "$line" =~ speed=(([0-9.]+)x?|N/A) ]]; then
        speed_raw="${BASH_REMATCH[1]}"
        speed="${speed_raw/x/}"
        if [[ "$speed" == "N/A" ]]; then
            speed=0
        fi
        echo "当前速度: $speed"
        current_time=$(date +%s)
        if ((current_time - last_check_time >= 1)); then
            if awk -v spd="$speed" 'BEGIN { exit (spd < 2) ? 0 : 1 }'; then
                ((counter++))
                echo "低速计数：$counter/3"
                if ((counter >= 3)); then
                    echo "[警告] 连续三次低速，终止进程"
                    kill -9 "$FFMPEG_PID" 2>/dev/null  # 强制终止
                    break
                fi
            else
                counter=0
            fi
            last_check_time=$current_time
        fi
    fi
done <&3

# 清理文件描述符
exec 3<&-
exit 0