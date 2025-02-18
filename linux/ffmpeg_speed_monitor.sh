# 初始化变量
last_check_time=0
counter=0

ffmpeg7 -i input.mp4 -c:v libx264 -c:a copy -crf 23 -preset medium out.mp4 -y -progress pipe:1 2>&1 | \
while IFS= read -r line; do
    echo "test: $line"
    if [[ "$line" =~ speed=([0-9.]+)x ]]; then
        speed="${BASH_REMATCH[1]}"
        echo "test2: $speed"
        current_time=$(date +%s)
        if (( current_time - last_check_time >= 2 )); then
echo "低速计数$speed"
            if awk -v spd="$speed" 'BEGIN { exit (spd < 2) ? 0 : 1 }'; then
                ((counter++))
                echo "低速计数：$counter/3"
                if (( counter >= 3 )); then
                    echo "[警告] 连续三次低速，终止进程"
                    pkill -P $$
                    exit 1
                fi
            else
                counter=0
            fi
            last_check_time=$current_time
        fi
    fi
done
