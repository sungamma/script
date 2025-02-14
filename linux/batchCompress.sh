#!/bin/bash

##############################################
# 视频压缩脚本（支持 H.264、H.265 和 VP9 编码）
# 版本：8.6 | 新增 -r 参数支持通配符模式
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

# 日志文件路径
LOGFILE="compress.log"

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

# 新增工具函数：兼容不同shell的nullglob设置
set_nullglob() {
    if [ -n "$BASH_VERSION" ]; then
        shopt -s nullglob 2>/dev/null
    elif [ -n "$ZSH_VERSION" ]; then
        setopt NULL_GLOB 2>/dev/null
    fi
}

unset_nullglob() {
    if [ -n "$BASH_VERSION" ]; then
        shopt -u nullglob 2>/dev/null
    elif [ -n "$ZSH_VERSION" ]; then
        unsetopt NULL_GLOB 2>/dev/null
    fi
}

log_to_top() {
    local log_content="$1"
    local temp_log="temp_compress.log"
    echo -e "$log_content" > "$temp_log"
    if [[ -f "$LOGFILE" ]]; then
        cat "$LOGFILE" >> "$temp_log"
    fi
    mv "$temp_log" "$LOGFILE"
}

show_help() {
    echo "用法: $0 [选项] [编码器...] [编码速度] [文件格式...] [s线程数] [文件...]"
    echo "选项:"
    echo "  -h, --help      显示此帮助信息"
    echo "  -crf <数值>     设置压缩质量（默认28）"
    echo "  -d <目录>       指定工作目录（默认当前目录）"
    echo "  -r <模式>       指定通配符模式（需用引号包裹）"
    echo "编码器:"
    echo "  ${SUPPORTED[ENCODERS]}"
    echo "文件格式:"
    echo "  all 或 ${SUPPORTED[FORMATS]}"
    echo "编码速度:"
    echo "  ${SUPPORTED[PRESETS]} (默认faster)"
    echo "线程数:"
    echo "  s1|s2|s3... (默认使用全部 $MAX_THREADS 线程)"
    echo "文件:"
    echo "  可选，指定单独处理的文件（支持通配符）"
    echo "示例:"
    echo "  # 使用-r参数处理通配符"
    echo "  $0 -r \"5*.mp4 1?.mkv\" x265"
    echo "  # 处理指定目录"
    echo "  $0 -d ~/Videos -r \"*.mp4\" vp9"
    exit 0
}

validate_params() {
    local args=("$@")
    local crf=28
    local preset="faster"
    local threads=$MAX_THREADS
    local directory="."
    local encoders=()
    local formats=()
    local files=()
    local patterns=()
    local position=0

    while (( position < ${#args[@]} )); do
        local arg="${args[position]}"

        case "$arg" in
            -h|--help) show_help ;;
            -crf)
                (( position++ ))
                crf="${args[position]}"
                [[ ! "$crf" =~ ^[0-9]+$ ]] && { echo "错误：无效的CRF值"; return 1; }
                ;;
            -d)
                (( position++ ))
                directory="${args[position]}"
                [[ ! -d "$directory" ]] && { echo "错误：目录不存在"; return 1; }
                directory=$(realpath "$directory")
                ;;
            -r)
                (( position++ ))
                IFS=' ' read -ra patterns <<< "${args[position]}"
                for pattern in "${patterns[@]}"; do
                    # 在指定目录下展开通配符
                    pushd "$directory" &>/dev/null
                    set_nullglob
                    local matched_files=($pattern)
                    unset_nullglob
                    popd &>/dev/null
                    
                    # 转换相对路径为绝对路径
                    if [[ ${#matched_files[@]} -gt 0 ]]; then
                        matched_files=("${matched_files[@]/#/$directory/}")
                        files+=("${matched_files[@]}")
                    else
                        echo "警告：未找到匹配的模式 '$pattern'"
                    fi
                done
                ;;
            s*)
                threads="${arg#s}"
                [[ ! "$threads" =~ ^[0-9]+$ ]] && { echo "错误：无效线程数"; return 1; }
                (( threads = threads > MAX_THREADS ? MAX_THREADS : threads ))
                ;;
            *)
                if [[ " ${SUPPORTED[PRESETS]} " =~ " $arg " ]]; then
                    preset="$arg"
                elif [[ " ${SUPPORTED[ENCODERS]} " =~ " $arg " ]]; then
                    encoders+=("$arg")
                elif [[ "$arg" == "all" || " ${SUPPORTED[FORMATS]} " =~ " $arg " ]]; then
                    [[ "$arg" == "all" ]] && formats=(${SUPPORTED[FORMATS]}) || formats+=("$arg")
                else
                    # 原有文件匹配逻辑保持不变
                    local matched_files=()
                    local need_convert_path=0

                    if [[ -n "$directory" && -d "$directory" ]]; then
                        pushd "$directory" &>/dev/null
                        set_nullglob
                        matched_files=($arg)
                        unset_nullglob
                        popd &>/dev/null
                        need_convert_path=1
                    else
                        set_nullglob
                        matched_files=($arg)
                        unset_nullglob
                    fi

                    if [[ ${#matched_files[@]} -gt 0 ]]; then
                        if (( need_convert_path )); then
                            matched_files=("${matched_files[@]/#/$directory/}")
                        fi
                        files+=("${matched_files[@]}")
                    else
                        echo "警告：未找到匹配的文件 '$arg'"
                    fi
                fi
                ;;
        esac
        (( position++ ))
    done

    # 后期验证（保持不变）
    [[ ${#encoders[@]} -eq 0 ]] && encoders=("x265")
    [[ ${#formats[@]} -eq 0 ]] && formats=("mp4")

    # 编码器CRF范围验证（保持不变）
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

    # 去重处理（保持不变）
    encoders=($(printf "%s\n" "${encoders[@]}" | sort -u))
    formats=($(printf "%s\n" "${formats[@]}" | sort -u))

    # 导出验证结果（保持不变）
    declare -g WORK_DIR="$directory"
    declare -g CRF=$crf
    declare -g PRESET=$preset
    declare -g THREADS=$threads
    declare -g ENCODERS=("${encoders[@]}")
    declare -g FORMATS=("${formats[@]}")
    declare -g FILES=("${files[@]}")
    return 0
}

process_file() {
    local src="$1" enc="$2"
    local base=$(basename "${src%.*}")
    local ext="${src##*.}"
    local dest="${WORK_DIR}/${base}-${enc}.${ext}"

   # 跳过已处理文件
    if [[ -f "$dest" ]] || [[ "$src" =~ -(x264|x265|vp9)\. ]]; then
        echo "跳过已处理文件：$src" | tee -a "$LOGFILE"
        return
    fi

    local start=$(date +%s)
    local start_time=$(date +"%Y-%m-%d %H:%M:%S")
    local orig_size=$(stat -c%s "$src")
    ((TOTAL_FILES++))

    echo "处理：$src ($(format_bytes $orig_size))" | tee -a "$LOGFILE"
    echo "开始时间：$start_time" | tee -a "$LOGFILE"

    local cmd="ffmpeg7 -hide_banner -i \"$src\""
    case "$enc" in
        x265) cmd+=" -c:v libx265 -crf $CRF -preset $PRESET -tag:v hvc1 -threads $THREADS" ;;
        x264) cmd+=" -c:v libx264 -crf $CRF -preset $PRESET -profile:v high -level 4.1 -threads $THREADS" ;;
        vp9)  cmd+=" -c:v libvpx-vp9 -crf $CRF -b:v 0 -row-mt 1 $(( THREADS > 1 ? "-threads $THREADS" : ""))" ;;
    esac
    cmd+=" -c:a copy \"$dest\""

    if eval $cmd 2>&1; then
        local comp_size=$(stat -c%s "$dest")
        ((PROCESSED++))
        TOTAL_ORIGIN=$((TOTAL_ORIGIN + orig_size))
        TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + comp_size))

        local end_time=$(date +"%Y-%m-%d %H:%M:%S")
        local duration=$(( $(date +%s) - start ))

        local log="文件：$src\n"
        log+="开始时间：$start_time\n"
        log+="结束时间：$end_time\n"
        log+="耗时：$(($duration / 3600))小时$((($duration / 60) % 60))分钟$(($duration % 60))秒\n"
        log+="原始：$(format_bytes $orig_size) → 压缩：$(format_bytes $comp_size)\n"
        log+="压缩率：$(awk "BEGIN {printf \"%.2f\", ($orig_size - $comp_size)/$orig_size*100}")%\n"
        FILE_STATS+=("$log")
    else
        echo "[错误] 处理失败：$src" | tee -a "$LOGFILE"
        rm -f "$dest"
    fi
}

main() {
        # 如果检测到zsh自动切换到bash
    if [ -n "$ZSH_VERSION" ]; then
        echo "提示：检测到 zsh 环境，自动切换至 bash 执行" | tee -a "$LOGFILE"
        exec bash "$0" "$@"
    fi
    # 参数验证
    if ! validate_params "$@"; then
        echo -e "\n支持的编码器：${SUPPORTED[ENCODERS]}" | tee -a "$LOGFILE"
        echo "支持的文件格式：${SUPPORTED[FORMATS]}" | tee -a "$LOGFILE"
        echo "支持的编码速度：${SUPPORTED[PRESETS]}" | tee -a "$LOGFILE"
        echo "最大支持线程数：$MAX_THREADS" | tee -a "$LOGFILE"
        show_help
        exit 1
    fi

    # 切换工作目录
    cd "$WORK_DIR" || { echo "无法进入目录：$WORK_DIR" | tee -a "$LOGFILE"; exit 1; }

    echo "==== 开始处理 ====" | tee -a "$LOGFILE"
    echo "工作目录：$WORK_DIR" | tee -a "$LOGFILE"
    echo "编码器：${ENCODERS[*]}" | tee -a "$LOGFILE"
    echo "文件格式：${FORMATS[*]}" | tee -a "$LOGFILE"
    echo "CRF值：$CRF" | tee -a "$LOGFILE"
    echo "编码速度：$PRESET" | tee -a "$LOGFILE"
    echo "使用线程数：$THREADS" | tee -a "$LOGFILE"
    echo "CPU最大线程数：$MAX_THREADS" | tee -a "$LOGFILE"

    # 优先处理单独指定的文件
    if [[ ${#FILES[@]} -gt 0 ]]; then
        for file in "${FILES[@]}"; do
            [[ -f "$file" ]] || continue
            for enc in "${ENCODERS[@]}"; do
                process_file "$file" "$enc"
            done
        done
    else
        # 处理格式匹配的文件
        for fmt in "${FORMATS[@]}"; do
            while IFS= read -r -d $'\0' file; do
                for enc in "${ENCODERS[@]}"; do
                    process_file "$file" "$enc"
                done
            done < <(find "$WORK_DIR" -maxdepth 1 -type f -name "*.$fmt" -print0)
        done
    fi

    # 生成报告
    echo -e "\n==== 处理完成 ====" | tee -a "$LOGFILE"
    echo "已处理：$PROCESSED/$TOTAL_FILES" | tee -a "$LOGFILE"
    echo "原始总量：$(format_bytes $TOTAL_ORIGIN)" | tee -a "$LOGFILE"
    echo "压缩总量：$(format_bytes $TOTAL_COMPRESSED)" | tee -a "$LOGFILE"
    echo "节省空间：$(format_bytes $((TOTAL_ORIGIN - TOTAL_COMPRESSED)))" | tee -a "$LOGFILE"
    echo -e "总耗时：$(($SECONDS / 3600))小时$((($SECONDS / 60) % 60))分钟$(($SECONDS % 60))秒\n" | tee -a "$LOGFILE"

    # 输出详细统计
    # [[ ${#FILE_STATS[@]} -gt 0 ]] && {
    if [[ ${#FILE_STATS[@]} -gt 0 ]]; then
        echo -e "==== 详细统计 ====" | tee -a "$LOGFILE"
        for log in "${FILE_STATS[@]}"; do
            echo -e "$log" | tee -a "$LOGFILE"
        done
    fi
    # }
}

trap 'echo "中断操作！"; exit 1' SIGINT
main "$@"
