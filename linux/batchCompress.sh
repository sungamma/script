#!/bin/bash

##############################################
# 视频压缩脚本（支持 H.264、H.265 和 VP9 编码）
# 版本：8.3.0 | 完善帮助，增加交互确认功能
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

# 显示帮助信息
show_help() {
    # 颜色定义
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[0;33m'
    local BLUE='\033[0;34m'
    local MAGENTA='\033[0;35m'
    local CYAN='\033[0;36m'
    local RESET='\033[0m' # 重置颜色

    echo -e "${GREEN}用法: $0 [选项] [编码器...] [编码速度] [文件格式...] [s线程数] [文件...]${RESET}"
    echo -e "${CYAN}说明:${RESET}"
    echo -e "  ${BLUE}1. 参数顺序可变${RESET}：选项、编码器、速度等参数可以任意顺序排列"
    echo -e "  ${BLUE}2. 特殊字符匹配${RESET}：指定文件时可使用通配符（如 \"1?.mp4\"），但需要加引号"
    echo -e "${CYAN}选项:${RESET}"
    echo -e "  ${YELLOW}-h, --help      ${RESET}显示此帮助信息"
    echo -e "  ${YELLOW}-crf <数值>     ${RESET}设置压缩质量（默认：x264=25, x265=28, vp9=30）"
    echo -e "  ${YELLOW}-y              ${RESET}自动确认，不提示输入"
    echo -e "  ${YELLOW}-d <目录>       ${RESET}指定工作目录（默认当前目录）"
    echo -e "  ${YELLOW}-depth <数值>   ${RESET}递归深度（0=无限，1=当前目录，2=一级子目录，默认1）"
    echo -e "  ${YELLOW}-r <模式...>    ${RESET}递归处理匹配模式的文件（例如：\"*.mp4 *.mkv\"）"
    echo -e "${CYAN}编码器:${RESET}"
    echo -e "  ${MAGENTA}${SUPPORTED[ENCODERS]}${RESET}"
    echo -e "${CYAN}文件格式:${RESET}"
    echo -e "  ${MAGENTA}all 或 ${SUPPORTED[FORMATS]}${RESET}"
    echo -e "${CYAN}编码速度:${RESET}"
    echo -e "  ${MAGENTA}${SUPPORTED[PRESETS]} ${RESET}(默认${GREEN}faster${RESET})"
    echo -e "${CYAN}线程数:${RESET}"
    echo -e "  ${MAGENTA}s1|s2|s3... ${RESET}(默认使用全部 ${GREEN}$MAX_THREADS${RESET} 线程)"
    echo -e "${CYAN}文件:${RESET}"
    echo -e "  可选，指定单独处理的文件（支持通配符，如 \"1?.mp4\"，需要加引号）"
    echo -e "${CYAN}示例:${RESET}"
    echo -e "  # 处理当前目录及一级子目录"
    echo -e "  ${GREEN}$0 -depth 2 -r \"*.mp4\" x265${RESET}"
    echo -e "  # 无限递归处理所有子目录"
    echo -e "  ${GREEN}$0 -depth 0 -r \"*.mkv\" vp9 -crf 35${RESET}"
    echo -e "  # 使用x264编码器，设置CRF为23"
    echo -e "  ${GREEN}$0 x264 -crf 23 fast s2${RESET}"
    echo -e "  # 处理特殊字符文件名"
    echo -e "  ${GREEN}$0 \"1?.mp4\" x265${RESET}"
    exit 0
}

# 参数验证系统
validate_params() {
    local args=("$@")
    local crf=28
    local preset="faster"
    local threads=$MAX_THREADS
    local directory="."
    local encoders=()
    local formats=()
    local files=()
    local position=0
    declare -g RECURSIVE=0
    declare -ga PATTERNS=()
    declare -gi DEPTH=1 # 默认递归深度为1
    declare -g SKIP_CONFIRM=0

    while ((position < ${#args[@]})); do
        local arg="${args[position]}"

        case "$arg" in
        -h | --help)
            show_help
            ;;
        -crf)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-crf 需要参数值"
                return 1
            }
            crf="${args[position]}"
            ;;
        -d)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-d 需要参数值"
                return 1
            }
            directory="${args[position]}"
            ;;
        -depth)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-depth 需要参数值"
                return 1
            }
            DEPTH="${args[position]}"
            if [[ ! "$DEPTH" =~ ^[0-9]+$ ]] || ((DEPTH < 0)); then
                echo "错误：无效的深度值 '$DEPTH'（必须≥0）"
                return 1
            fi
            ;;
        -r)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-r 需要参数值"
                return 1
            }
            IFS=' ' read -ra PATTERNS <<<"${args[position]}"
            RECURSIVE=1
            ;;
        -y)
            SKIP_CONFIRM=1
            ;;
        s*)
            threads="${arg#s}"
            [[ ! "$threads" =~ ^[0-9]+$ ]] && {
                echo "错误：无效的线程数格式 '$arg'"
                return 1
            }
            ((threads > MAX_THREADS)) && {
                echo "错误：线程数超过最大值（最大支持 $MAX_THREADS 线程）"
                return 1
            }
            ((threads < 1)) && {
                echo "错误：线程数不能小于1"
                return 1
            }
            ;;
        *)
            if [[ " ${SUPPORTED[PRESETS]} " =~ " $arg " ]]; then
                preset="$arg"
            elif [[ " ${SUPPORTED[ENCODERS]} " =~ " $arg " ]]; then
                encoders+=("$arg")
            elif [[ "$arg" == "all" || " ${SUPPORTED[FORMATS]} " =~ " $arg " ]]; then
                [[ "$arg" == "all" ]] && formats=(${SUPPORTED[FORMATS]}) || formats+=("$arg")
            elif [[ -f "$directory/$arg" || -f "$arg" ]]; then
                files+=("$arg")
            else
                echo "错误：无效参数 '$arg'"
                return 1
            fi
            ;;
        esac
        ((position++))
    done

    # 后期验证
    [[ ${#encoders[@]} -eq 0 ]] && encoders=("x265")
    [[ ${#formats[@]} -eq 0 ]] && formats=("mp4")

    # 编码器CRF范围验证
    for enc in "${encoders[@]}"; do
        case $enc in
        x264)
            crf=${crf:-25}
            ((crf < 0 || crf > 51)) && {
                echo "错误：$enc 的CRF范围应为 ${SUPPORTED[X264_CRF]}"
                return 1
            }
            ;;
        x265)
            crf=${crf:-28}
            ((crf < 0 || crf > 51)) && {
                echo "错误：$enc 的CRF范围应为 ${SUPPORTED[X265_CRF]}"
                return 1
            }
            ;;
        vp9)
            crf=${crf:-30}
            ((crf < 0 || crf > 63)) && {
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
    declare -g FILES=("${files[@]}")
    declare -g RECURSIVE
    declare -ga PATTERNS
    declare -g DEPTH
    return 0
}

# 文件处理
process_file() {
    local src="$1" enc="$2"
    local base="${src%.*}" ext="${src##*.}"
    local dest="${base}-${enc}.${ext}"

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
        ((THREADS > 1)) && cmd+=" -threads $THREADS"
        ;;
    esac
    cmd+=" -c:a copy \"$dest\""

    if eval $cmd 2>&1; then
        local comp_size=$(stat -c%s "$dest")
        ((PROCESSED++))
        TOTAL_ORIGIN=$((TOTAL_ORIGIN + orig_size))
        TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + comp_size))

        local end_time=$(date +"%Y-%m-%d %H:%M:%S")
        local duration=$(($(date +%s) - start))

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

# 主函数
main() {
    # 参数验证
    if ! validate_params "$@"; then
        echo -e "\n支持的编码器：${SUPPORTED[ENCODERS]}" | tee -a "$LOGFILE"
        echo "支持的文件格式：${SUPPORTED[FORMATS]}" | tee -a "$LOGFILE"
        echo "支持的编码速度：${SUPPORTED[PRESETS]}" | tee -a "$LOGFILE"
        echo "最大支持线程数：$MAX_THREADS" | tee -a "$LOGFILE"
        exit 1
    fi

    # 切换工作目录
    cd "$WORK_DIR" || {
        echo "无法进入目录：$WORK_DIR" | tee -a "$LOGFILE"
        exit 1
    }
    echo "工作目录：$(pwd)" | tee -a "$LOGFILE"

    # 执行压缩
    echo "==== 开始处理 ====" | tee -a "$LOGFILE"
    echo "编码器：${ENCODERS[*]}" | tee -a "$LOGFILE"
    echo "文件格式：${FORMATS[*]}" | tee -a "$LOGFILE"
    echo "CRF值：$CRF" | tee -a "$LOGFILE"
    echo "编码速度：$PRESET" | tee -a "$LOGFILE"
    echo "使用线程数：$THREADS" | tee -a "$LOGFILE"
    echo "CPU最大线程数：$MAX_THREADS" | tee -a "$LOGFILE"
    echo "递归深度：$([[ $DEPTH -eq 0 ]] && echo '无限' || echo $DEPTH)" | tee -a "$LOGFILE"

    # 处理逻辑分支
    if [[ $RECURSIVE -eq 1 ]]; then
        echo "递归模式：${PATTERNS[*]}" | tee -a "$LOGFILE"
        find_cmd="find ."

        # 构建find命令
        ((DEPTH > 0)) && find_cmd+=" -maxdepth $DEPTH"
        find_cmd+=" -type f"
        if [[ ${#PATTERNS[@]} -gt 0 ]]; then
            find_cmd+=" \( "
            for ((i = 0; i < ${#PATTERNS[@]}; i++)); do
                pattern=${PATTERNS[$i]}
                [[ $i -gt 0 ]] && find_cmd+=" -o "
                find_cmd+=" -name \"$pattern\""
            done
            find_cmd+=" \)"
        fi
        find_cmd+=" ! -name \"*-x265.*\" ! -name \"*-x264.*\" ! -name \"*-vp9.*\""

         
# 读取文件并过滤非视频格式
file_array=()
while IFS= read -r file; do
    # 获取文件扩展名并转换为小写
    local ext="${file##*.}"
    ext="${ext,,}"

    # 检查是否为支持的视频格式
    if [[ " ${SUPPORTED[FORMATS]} " =~ " $ext " ]]; then
        file_array+=("$file")
    fi
done < <(eval "$find_cmd")
 

        # 显示找到的文件
        echo "执行查找命令：$find_cmd" | tee -a "$LOGFILE"
        echo "找到的视频文件列表：" | tee -a "$LOGFILE"
        for file in "${file_array[@]}"; do
            echo "$file" | tee -a "$LOGFILE"
        done

        # 用户确认
        if [[ $SKIP_CONFIRM -eq 0 ]]; then
            read -p "找到以上 ${#file_array[@]} 个文件，是否继续处理？[y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && {
                echo "操作已取消" | tee -a "$LOGFILE"
                exit 0
            }
        fi

        # 处理文件
        for file in "${file_array[@]}"; do
            for enc in "${ENCODERS[@]}"; do
                process_file "$file" "$enc"
            done
        done

    elif [[ ${#FILES[@]} -gt 0 ]]; then
        # 显示指定文件
        echo "指定文件列表：" | tee -a "$LOGFILE"
        for file in "${FILES[@]}"; do
            [[ -f "$file" ]] && echo "$file" | tee -a "$LOGFILE"
        done

        # 用户确认
        if [[ $SKIP_CONFIRM -eq 0 ]]; then
            read -p "找到以上 ${#FILES[@]} 个文件，是否继续处理？[y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && {
                echo "操作已取消" | tee -a "$LOGFILE"
                exit 0
            }
        fi

        # 处理文件
        for file in "${FILES[@]}"; do
            [[ -f "$file" ]] || continue
            for enc in "${ENCODERS[@]}"; do
                process_file "$file" "$enc"
            done
        done

    else
        # 显示格式匹配的文件
        echo "找到的文件列表：" | tee -a "$LOGFILE"
        for fmt in "${FORMATS[@]}"; do
            for file in *."$fmt"; do
                [[ -f "$file" ]] && echo "$file" | tee -a "$LOGFILE"
            done
        done

        # 用户确认
        if [[ $SKIP_CONFIRM -eq 0 ]]; then
            read -p "找到以上文件，是否继续处理？[y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && {
                echo "操作已取消" | tee -a "$LOGFILE"
                exit 0
            }
        fi

        # 处理文件
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
    echo -e "\n==== 处理完成 ====" | tee -a "$LOGFILE"
    echo "已处理：$PROCESSED/$TOTAL_FILES" | tee -a "$LOGFILE"
    echo "原始总量：$(format_bytes $TOTAL_ORIGIN)" | tee -a "$LOGFILE"
    echo "压缩总量：$(format_bytes $TOTAL_COMPRESSED)" | tee -a "$LOGFILE"
    echo "节省空间：$(format_bytes $((TOTAL_ORIGIN - TOTAL_COMPRESSED)))" | tee -a "$LOGFILE"
    if [[ $TOTAL_ORIGIN -gt 0 ]]; then
        echo "压缩率：$(awk "BEGIN {printf \"%.2f\", ($TOTAL_ORIGIN - $TOTAL_COMPRESSED)/$TOTAL_ORIGIN*100}")%" | tee -a "$LOGFILE"
    fi

    # 输出总耗时
    duration=$SECONDS
    echo -e "总耗时：$(($duration / 3600))小时$((($duration / 60) % 60))分钟$(($duration % 60))秒\n" | tee -a "$LOGFILE"

    # 输出详细统计
    if [[ ${#FILE_STATS[@]} -gt 0 ]]; then
        echo -e "==== 详细统计 ====" | tee -a "$LOGFILE"
        for log in "${FILE_STATS[@]}"; do
            echo -e "$log" | tee -a "$LOGFILE"
        done
    fi
}

trap 'echo "中断操作！"; exit 1' SIGINT
# 脚本入口
main "$@"
