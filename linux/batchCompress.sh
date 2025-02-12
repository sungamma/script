#!/bin/bash

##############################################
# 视频压缩脚本（支持 H.264、H.265 和 VP9 编码）
# 版本：7.2 | 单独文件支持版
##############################################

SECONDS=0

# 全局配置
declare -A SUPPORTED=(
    ["ENCODERS"]="x264 x265 vp9"
    ["FORMATS"]="mp4 mkv avi flv mov wmv mpg mpeg"
    ["PRESETS"]="ultrafast superfast veryfast faster fast medium slow slower veryslow"
    ["X264_CRF"]="0-51"
    ["X265_CRF"]="0-51"
    ["VP9_CRF"]="0-63"
)

# 获取CPU信息
MAX_THREADS=$(nproc)
declare -i MAX_THREADS

# 统计变量
declare -i TOTAL_FILES=0
declare -i PROCESSED=0
declare -a FILE_STATS
TOTAL_ORIGIN=0
TOTAL_COMPRESSED=0

start_timestamp=$(date +"%Y-%m-%d %H:%M:%S")

# 工具函数
format_bytes() {
    awk -v bytes="$1" '
    BEGIN {
        suffix="BKMGT"
        while (bytes >= 1024 && length(suffix) > 1) {
            bytes /= 1024
            suffix = substr(suffix, 2)
        }
        printf("%.2f%s", bytes, substr(suffix,1,1))
    }'
}

show_usage() {
    echo "用法: $0 [选项] [编码器...] [编码速度] [文件格式...] [s线程数] [文件...]"
    echo "选项:"
    echo "  -crf <数值>   设置压缩质量（默认28）"
    echo "  -d <目录>     指定工作目录（默认当前目录）"
    echo "编码器:"
    echo "  ${SUPPORTED[ENCODERS]}"
    echo "文件格式:"
    echo "  all 或 ${SUPPORTED[FORMATS]}"
    echo "编码速度:"
    echo "  ${SUPPORTED[PRESETS]}"
    echo "线程数:"
    echo "  s1|s2|s3... (默认使用全部 $MAX_THREADS 线程)"
    echo "文件:"
    echo "  可选，指定单独处理的文件"
    echo "示例:"
    echo "  # 处理当前目录"
    echo "  $0 x265 fast mkv"
    echo "  # 处理指定目录"
    echo "  $0 -d ~/Videos all vp9 -crf 30 medium s4"
    echo "  # 处理指定文件"
    echo "  $0 a.mp4 b.mkv fast x264"
}

# 参数验证系统
validate_params() {
    local args=("$@")
    local crf=28
    local preset="faster"
    local threads=$MAX_THREADS  # 默认使用最大线程
    local directory="."
    local encoders=()
    local formats=()
    local files=()  # 新增单独文件列表
    local position=0

    while (( position < ${#args[@]} )); do
        local arg="${args[position]}"

        case "$arg" in
            -crf)
                (( position++ ))
                [[ -z "${args[position]}" ]] && { echo "错误：-crf 需要参数值"; return 1; }
                [[ ! "${args[position]}" =~ ^[0-9]+$ ]] && { echo "错误：无效的CRF值 '${args[position]}'"; return 1; }
                crf="${args[position]}"
                ;;
            -d)
                (( position++ ))
                [[ -z "${args[position]}" ]] && { echo "错误：-d 需要目录参数"; return 1; }
                directory="${args[position]}"
                [[ ! -d "$directory" ]] && { echo "错误：目录不存在 '$directory'"; return 1; }
                ;;
            s*)
                threads="${arg#s}"
                [[ ! "$threads" =~ ^[0-9]+$ ]] && { echo "错误：无效的线程数格式 '$arg'"; return 1; }
                (( threads > MAX_THREADS )) && {
                    echo "错误：线程数超过最大值（最大支持 $MAX_THREADS 线程）"; return 1; }
                (( threads < 1 )) && { echo "错误：线程数不能小于1"; return 1; }
                ;;
            *)
                if [[ " ${SUPPORTED[PRESETS]} " =~ " $arg " ]]; then
                    preset="$arg"
                elif [[ " ${SUPPORTED[ENCODERS]} " =~ " $arg " ]]; then
                    encoders+=("$arg")
                elif [[ "$arg" == "all" || " ${SUPPORTED[FORMATS]} " =~ " $arg " ]]; then
                    [[ "$arg" == "all" ]] && formats=(${SUPPORTED[FORMATS]}) || formats+=("$arg")
                elif [[ -f "$directory/$arg" ]]; then  # 检查文件是否存在
                    files+=("$arg")
                else
                    echo "错误：无效参数 '$arg'"
                    return 1
                fi
                ;;
        esac
        (( position++ ))
    done

    # 后期验证
    [[ ${#encoders[@]} -eq 0 ]] && encoders=("x265")
    [[ ${#formats[@]} -eq 0 ]] && formats=("mp4")

    # 编码器CRF范围验证
    for enc in "${encoders[@]}"; do
        case $enc in
            x264)
                (( crf < 0 || crf > 51 )) && {
                    echo "错误：$enc 的CRF范围应为 ${SUPPORTED[X264_CRF]}"
                    return 1
                }
                ;;
            x265)
                (( crf < 0 || crf > 51 )) && {
                    echo "错误：$enc 的CRF范围应为 ${SUPPORTED[X265_CRF]}"
                    return 1
                }
                ;;
            vp9)
                (( crf < 0 || crf > 63 )) && {
                    echo "错误：vp9 的CRF范围应为 ${SUPPORTED[VP9_CRF]}"
                    return 1
                }
                ;;
        esac
    done

    # 去重处理
    encoders=($(printf "%s\n" "${encoders[@]}" | sort -u))
    formats=($(printf "%s\n" "${formats[@]}" | sort -u))

    # 导出验证结果
    declare -g WORK_DIR="$directory"
    declare -g CRF=$crf
    declare -g PRESET=$preset
    declare -g THREADS=$threads
    declare -g ENCODERS=("${encoders[@]}")
    declare -g FORMATS=("${formats[@]}")
    declare -g FILES=("${files[@]}")  # 新增单独文件列表
    return 0
}

# 文件处理
process_file() {
    local src="$1" enc="$2"
    local base="${src%.*}" ext="${src##*.}"
    local dest="${base}-${enc}.${ext}"

    # 跳过已处理文件
    if [[ -f "$dest" ]] || [[ "$src" =~ -(x264|x265|vp9)\. ]]; then
        echo "跳过已处理文件：$src" | tee -a compress.log
        return
    fi

    local start=$(date +%s)
    local orig_size=$(stat -c%s "$src")
    ((TOTAL_FILES++))

    echo "处理：$src ($(format_bytes $orig_size))" | tee -a compress.log

    local cmd="ffmpeg7 -hide_banner -i \"$src\""
    case "$enc" in
        x265)
            cmd+=" -c:v libx265 -crf $CRF -preset $PRESET"
            cmd+=" -tag:v hvc1 -threads $THREADS"
            ;;
        x264)
            cmd+=" -c:v libx264 -crf $CRF -preset $PRESET"
            cmd+=" -profile:v high -level 4.1 -threads $THREADS"
            ;;
        vp9)
            cmd+=" -c:v libvpx-vp9 -crf $CRF -b:v 0 -row-mt 1"
            (( THREADS > 1 )) && cmd+=" -threads $THREADS"
            ;;
    esac
    cmd+=" -c:a copy \"$dest\""

    if eval $cmd 2>&1; then
        local comp_size=$(stat -c%s "$dest")
        ((PROCESSED++))
        TOTAL_ORIGIN=$((TOTAL_ORIGIN + orig_size))
        TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + comp_size))

        local log="文件：$src\n"
        log+="编码方案：$enc\n"
        log+="CRF值：$CRF | 线程数：$THREADS\n"
        log+="编码速度：$PRESET\n"
        log+="耗时：$(date -d@$(($(date +%s)-start)) -u +%Hh%Mm%Ss)\n"
        log+="原始：$(format_bytes $orig_size) → 压缩：$(format_bytes $comp_size)\n"
        log+="压缩率：$(awk "BEGIN {printf \"%.2f\", ($orig_size - $comp_size)/$orig_size*100}")%\n"
        FILE_STATS+=("$log")
    else
        echo "[错误] 处理失败：$src" | tee -a compress.log
        rm -f "$dest"
    fi
}

# 主函数
main() {
    # 参数验证
    if ! validate_params "$@"; then
        echo -e "\n支持的编码器：${SUPPORTED[ENCODERS]}"
        echo "支持的文件格式：${SUPPORTED[FORMATS]}"
        echo "支持的编码速度：${SUPPORTED[PRESETS]}"
        echo "最大支持线程数：$MAX_THREADS"
        show_usage
        exit 1
    fi

    # 切换工作目录
    cd "$WORK_DIR" || { echo "无法进入目录：$WORK_DIR"; exit 1; }
    echo "工作目录：$(pwd)" | tee -a compress.log

    # 执行压缩
    echo "==== 开始处理 ====" | tee -a compress.log
    echo "编码器：${ENCODERS[*]}" | tee -a compress.log
    echo "文件格式：${FORMATS[*]}" | tee -a compress.log
    echo "CRF值：$CRF" | tee -a compress.log
    echo "编码速度：$PRESET" | tee -a compress.log
    echo "使用线程数：$THREADS" | tee -a compress.log
    echo "CPU最大线程数：$MAX_THREADS" | tee -a compress.log

    # 如果指定了单独文件，只处理这些文件
    if [[ ${#FILES[@]} -gt 0 ]]; then
        for file in "${FILES[@]}"; do
            [[ -f "$file" ]] || continue
            for enc in "${ENCODERS[@]}"; do
                process_file "$file" "$enc"
            done
        done
    else
        # 否则处理指定目录中的文件
        for fmt in "${FORMATS[@]}"; do
            for file in *."$fmt"; do
                [[ -f "$file" ]] || continue
                for enc in "${ENCODERS[@]}"; do
                    process_file "$file" "$enc"
                done
            done
        done
    fi

    # 生成报告
    echo -e "\n==== 处理完成 ====" | tee -a compress.log
    echo "已处理：$PROCESSED/$TOTAL_FILES" | tee -a compress.log
    echo "原始总量：$(format_bytes $TOTAL_ORIGIN)" | tee -a compress.log
    echo "压缩总量：$(format_bytes $TOTAL_COMPRESSED)" | tee -a compress.log
    echo "节省空间：$(format_bytes $((TOTAL_ORIGIN - TOTAL_COMPRESSED)))" | tee -a compress.log

    [[ ${#FILE_STATS[@]} -gt 0 ]] && {
        echo -e "\n详细统计：" | tee -a compress.log
        for log in "${FILE_STATS[@]}"; do
            echo -e "$log" | tee -a compress.log
        done
    }

    # 输出总耗时
    duration=$SECONDS
    echo "总耗时：$(($duration / 3600))小时$((($duration / 60) % 60))分钟$(($duration % 60))秒" | tee -a compress.log
}

# 脚本入口
main "$@"