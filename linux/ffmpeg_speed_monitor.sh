ffmpeg7 -i input.mp4 -c:v libx264 -c:a copy -crf 23 -preset medium  out.mp4 -y -progress pipe:1 2>&1 | \
while IFS= read -r line; do
    echo "test: $line"  # 输出当前行
    if [[ "$line" =~ speed=([0-9.]+)x ]]; then
        speed="${BASH_REMATCH[1]}"
        echo "test2: $speed"  # 输出匹配到的速度
        if awk -v spd="$speed" 'BEGIN { exit (spd < 0.05) ? 0 : 1 }'; then
            echo "[警告] 处理速度过低: ${speed}x，终止进程"
            pkill -P $$
            exit 1
        fi
    fi
done
