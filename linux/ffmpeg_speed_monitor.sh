#!/usr/bin/env bash

# ============================== 配置参数 ==============================
MIN_SPEED=1    # 最低允许编码速度（单位：fps）
PRESET="fast"  # x265编码预设参数
CRF=28         # 质量系数
THREADS=4      # 并行线程数
CONSECUTIVE_THRESHOLD=3  # 连续低于阈值的次数

# ============================== 主流程 ==============================
main() {
    local input_file="$1"
    local output_file="${input_file%.*}_x265.mp4"
    local progress_file="ffmpeg_progress.txt"
    local speed_count=0

    # 启动编码进程，并将进度输出到文件
    ffmpeg7 -hide_banner -nostdin -y \
        -i "$input_file" \
        -c:v libx265 -preset "$PRESET" -crf "$CRF" -threads "$THREADS" \
        -c:a copy \
        -progress "$progress_file" \
        "$output_file" > /dev/null 2>&1 &

    ffmpeg_pid=$!

    # 等待进度文件生成
    while [ ! -f "$progress_file" ]; do
        sleep 0.1
    done

    # 监控进度文件
    while true; do
        # 检查ffmpeg进程是否还在运行
        if ! kill -0 $ffmpeg_pid 2>/dev/null; then
            break
        fi

        # 获取最新的进度信息
        local speed_line=$(tail -1 "$progress_file")
        if [[ $speed_line =~ ^speed=([0-9.]+)x ]]; then
            speed="${BASH_REMATCH[1]}"
        else
            speed=$(grep ^speed= "$progress_file" | awk -F '[=x]' '{print $2}' | tail -1)
        fi

        if [[ -n "$speed" ]]; then
            # 仅当速度为有效数字时处理
            if [[ "$speed" =~ ^[0-9.]+$ ]]; then
                printf "[进度] 当前速度：%sx\n" "$speed"
                # echo "编码速度${speed}x低于${MIN_SPEED}x"

                # 使用awk进行浮点数比较
                # if awk -v s="$speed" -v min="$MIN_SPEED" 'BEGIN { exit (s < min) }'; then
                if awk "BEGIN {exit !($MIN_SPEED > $speed)}"; then
                    echo "编码速度${speed}x低于${MIN_SPEED}x"
                    ((speed_count++))
                    if (( speed_count >= CONSECUTIVE_THRESHOLD )); then
                        echo "[错误] 编码速度连续$CONSECUTIVE_THRESHOLD次低于${MIN_SPEED}x"
                        echo "FFmpeg PID: $ffmpeg_pid"
                        if kill -KILL $ffmpeg_pid 2>/dev/null; then
                            echo "进程终止信号已发送"
                        fi
                        break
                    fi
                else
                    speed_count=0
                fi
            else
                echo "[警告] 无效的编码速度：$speed"
            fi
        fi

        sleep 1
    done

    wait $ffmpeg_pid

    # 结果检查
    if [ $? -eq 0 ]; then
        echo "[完成] 编码成功：$output_file"
    else
        echo "[失败] 编码异常终止"
        rm -f "$output_file"
    fi

    # 删除进度文件
    rm -f "$progress_file"
}

# ============================== 执行入口 ==============================
if [ $# -ne 1 ]; then
    echo "用法：$0 视频文件"
    exit 1
fi

main "$1"