#!/bin/bash

##############################################
# 视频压缩脚本（支持 H.264、H.265 和 VP9 编码）
# 版本：10.2.0 | 增加自动移动源文件到 originals_bak 文件夹
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
# 新增全局变量（修改点1）
declare -g FFMPEG_PID=0
declare -g FFMPEG_PGID=0
declare -g SPEED_THRESHOLD=0

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

# 增强中断处理（修改点2）
trap 'handle_interrupt' SIGINT

# 在 handle_interrupt 中移除危险操作
handle_interrupt() {
    echo -e "\n[强制终止] 安全终止中..."
    [[ $FFMPEG_PID -gt 0 ]] && {
        kill -SIGTERM $FFMPEG_PID 2>/dev/null
        sleep 0.5
        kill -SIGKILL $FFMPEG_PID 2>/dev/null
    }
    exit 1
}

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

# 修改点1：增强进程终止函数
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

    echo -e "${GREEN}用法: $0 [选项] [编码器...] [编码速度] [文件格式...] [线程数] [文件...]${RESET}"
    echo -e "${CYAN}说明:${RESET}"
    echo -e "${CYAN}其他选项保持不变...${RESET}"
    echo -e "  ${YELLOW}1. 参数顺序可变${RESET}：选项、编码器、速度等参数可以任意顺序排列"
    echo -e "  ${YELLOW}2. 特殊字符匹配${RESET}：指定文件时可使用通配符（如 \"1?.mp4\"），但需要加引号"
    echo -e "${CYAN}选项:${RESET}"
    echo -e "  ${YELLOW}-h, --help      ${RESET}显示此帮助信息"
    echo -e "  ${YELLOW}-crf <数值>     ${RESET}设置压缩质量（默认：x264=25, x265=28, vp9=30）"
    echo -e "  ${YELLOW}-m              ${RESET}自动移动源文件到 originals_bak 文件夹"
    echo -e "  ${YELLOW}-s <数值>       ${RESET}设置线程数(默认使用全部 ${GREEN}$MAX_THREADS${RESET} 线程)"
    echo -e "  ${YELLOW}-y              ${RESET}自动确认源文件，不提示输入，若需无人值守运行，请使用-y选项及-m选项"
    echo -e "  ${YELLOW}-d <目录>       ${RESET}指定工作目录（默认当前目录）"
    echo -e "  ${YELLOW}-r <深度>  <通配符文件>    ${RESET}递归深度（0=无限，1=当前目录，2=一级子目录，默认1）,递归处理匹配通配符文件（例如：\"*.mp4 *.mkv\"）"
    echo -e "  ${YELLOW}-sp <数值>      ${RESET}设置最低允许转码速度(单位：倍速)，连续3次低于该值则跳过并重命名文件，增加后缀 _skipped"
    echo -e "${CYAN}编码器:${RESET}"
    echo -e "  ${MAGENTA}${SUPPORTED[ENCODERS]}${RESET}"
    echo -e "${CYAN}文件格式:${RESET}"
    echo -e "  ${MAGENTA}all 或 ${SUPPORTED[FORMATS]}${RESET}"
    echo -e "${CYAN}编码速度:${RESET}"
    echo -e "  ${MAGENTA}${SUPPORTED[PRESETS]} ${RESET}(默认${GREEN}faster${RESET})"
    echo -e "${CYAN}文件:${RESET}"
    echo -e "  可选，指定单独处理的文件（支持通配符，如 \"1?.mp4\"，需要加引号）"
    echo -e "${CYAN}示例:${RESET}"
    echo -e "  # 处理当前目录及一级子目录"
    echo -e "  ${GREEN}$0 -r 2 \"*.mp4\" x265${RESET}"
    echo -e "  # 处理当前目录下5开头的mp4文件和6开头的mkv文件"
    echo -e "  ${GREEN}$0 -r  \"5*.mp4 6*.mkv\" x265${RESET}"
    echo -e "  # 无限递归处理所有子目录"
    echo -e "  ${GREEN}$0 -r 0 \"*.mkv\" vp9 -crf 35${RESET}"
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
    declare -g DEPTH=1 # 默认递归深度为1
    declare -g SKIP_CONFIRM=0
    declare -g MOVE_FILES=0

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
        -r)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-r 需要参数值"
                return 1
            }

            # 检查是否提供递归深度
            DEPTH="${args[$position]}"
            if [[ "$DEPTH" =~ ^[0-9]+$ ]]; then
                ((DEPTH < 0)) && {
                    echo "错误：无效的深度值 '$DEPTH'（必须为非负整数）"
                    return 1
                }
                ((position++)) # 移动到下一个参数（文件模式）
                [[ $position -ge ${#args[@]} ]] && {
                    echo "错误：-r 需要文件模式"
                    return 1
                }
            else
                # 如果参数不是数字，则默认为深度1，当前参数是文件模式
                DEPTH=1
            fi

            # 读取文件模式
            IFS=' ' read -ra PATTERNS <<<"${args[position]}"
            RECURSIVE=1
            ;;
        -y)
            SKIP_CONFIRM=1
            ;;
        -m)
            MOVE_FILES=1
            ;;
        -s)
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-s 需要参数值"
                return 1
            }
            threads="${args[position]}"
            [[ ! "$threads" =~ ^[0-9]+$ ]] && {
                echo "错误：无效的线程数格式 '$threads'"
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
        -sp) # 新增参数处理
            ((position++))
            [[ $position -ge ${#args[@]} ]] && {
                echo "错误：-sp 需要参数值"
                return 1
            }
            SPEED_THRESHOLD="${args[position]}"
            [[ ! "$SPEED_THRESHOLD" =~ ^[0-9.]+$ ]] && {
                echo "错误：无效的速度阈值格式 '$SPEED_THRESHOLD'"
                return 1
            }
            ;;
        *)
            if [[ " ${SUPPORTED[PRESETS]} " =~ " $arg " ]]; then
                preset="$arg"
            elif [[ " ${SUPPORTED[ENCODERS]} " =~ " $arg " ]]; then
                encoders+=("$arg")
            # 修改点1：参数格式统一小写
            elif [[ "$arg" == "all" ]] || [[ " ${SUPPORTED[FORMATS]} " =~ " ${arg,,} " ]]; then
                [[ "$arg" == "all" ]] && formats=(${SUPPORTED[FORMATS]}) || formats+=("${arg,,}")
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

process_file() {
    local src="$1" enc="$2"
    local base="${src%.*}" ext="${src##*.}"
    # 修改点3：统一小写判断
    local ext_lower="${ext,,}"
    if [[ ! " ${FORMATS[@]} " =~ " $ext_lower " ]]; then
        echo "跳过不支持格式的文件：$src" | tee -a "$LOGFILE"
        return
    fi
    local dest="${base}-${enc}.${ext}"
    local exit_status=127
    local FFMPEG_PID=0 FFMPEG_PGID=0
    last_check_time=0
    counter=0
    # 新增状态变量（converting-转换中/skipped_existing-已存在跳过/skipped_speed-低速跳过/converted-转换成功/failed-转换失败）
    local status="converting"
    local skipped_file=""

    # 增强型文件跳过检查
    if { [[ -f "$dest" ]] && [[ $(stat -c%s "$dest") -gt 1024 ]]; } ||
        [[ "$src" =~ -(x264|x265|vp9|skipped)\. ]]; then
        echo "跳过已处理文件：$src" | tee -a "$LOGFILE"
        status="skipped_existing"
    else
        # 初始化统计信息
        local start=$(date +%s)
        local start_time=$(date +"%Y-%m-%d %H:%M:%S")
        local orig_size=$(stat -c%s "$src")
        ((TOTAL_FILES++))

        # 构建ffmpeg命令（群晖兼容版）
        local cmd="ffmpeg7 -hide_banner -nostdin -y -i \"$src\""
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
        cmd+=" -c:a copy -progress pipe:1 \"$dest\"  2>&1"

        # 启动 ffmpeg7 并通过进程替换捕获输出
        echo "启动进程..."
        exec 3< <(eval "$cmd")
        echo "进程已启动"
        FFMPEG_PID=$!
        echo "进程 PID: $FFMPEG_PID"
        wait 1
        CHILD_PID=$(ps --ppid $FFMPEG_PID | grep -v PID | awk '{print $1}')
        echo "子进程 PID: $CHILD_PID"
        FFMPEG_PID=$CHILD_PID

        # 进度监控
        while IFS= read -r line; do
            echo "FFMPEG输出: $line"
            if [[ "$line" =~ speed=(([0-9.]+)x?|N/A) ]]; then
                speed_raw="${BASH_REMATCH[1]}"
                speed="${speed_raw/x/}"
                if [[ "$speed" == "N/A" ]]; then
                    speed=0
                fi
                echo "当前速度: $speed"

                current_time=$(date +%s)
                if ((current_time - last_check_time >= 1)); then
                    if awk -v spd="$speed" -v threshold="$SPEED_THRESHOLD" 'BEGIN { exit (spd < threshold) ? 0 : 1 }'; then
                        ((counter++))
                        echo "低速计数：$counter/3"
                        if ((counter >= 3)); then
                            echo "[警告] 连续三次低速，终止进程"
                            status="skipped_speed"
                            skipped_file="${src%.*}-skipped.${ext}"
                            kill -SIGKILL "$FFMPEG_PID" 2>/dev/null
                            sleep 1
                            rm -f "$dest"
                            mv -n "$src" "$skipped_file"
                            break
                        fi
                    else
                        counter=0
                    fi
                    last_check_time=$current_time
                fi
            fi
        done <&3

        exec 3<&-

        # 获取最终退出状态
        exit_status=$?

        # 根据退出状态更新状态变量
        if [[ $status != "skipped_speed" ]]; then
            if [[ $exit_status -eq 0 ]]; then
                local comp_size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
                if ((comp_size > 0 && comp_size < orig_size)); then
                    status="converted"
                else
                    status="failed"
                fi
            else
                status="failed"
            fi
        fi
    fi # 结束主处理逻辑

    # 统一日志记录
    local log=""
    case "$status" in
    "skipped_existing")
        log="文件：$src\n状态：已跳过（目标文件已存在）\n"
        ;;
    "skipped_speed")
        log="文件：$src\n开始时间：$start_time\n"
        log+="状态：因速度过低中止\n源文件已重命名为：$skipped_file \n"
        ;;
    "converted")
        local duration=$(($(date +%s) - start))
        log="文件：$src\n开始时间：$start_time\n耗时：$(printf "%02dh%02dm%02ds" $((duration / 3600)) $((duration % 3600 / 60)) $((duration % 60)))"
        log+="\n原始：$(format_bytes $orig_size) → 压缩：$(format_bytes $comp_size)"
        log+="\n压缩率：$(awk "BEGIN {printf \"%.2f\", ($orig_size - $comp_size)/$orig_size*100}")%\n"
        ((PROCESSED++))
        TOTAL_ORIGIN=$((TOTAL_ORIGIN + orig_size))
        TOTAL_COMPRESSED=$((TOTAL_COMPRESSED + comp_size))
        ;;
    "failed")
        log="文件：$src\n状态：转换失败\n"
        ;;
    esac
    [[ -n "$log" ]] && FILE_STATS+=("$log")

    # 文件移动处理（仅在转换成功时执行）
    if [[ $status == "converted" && $MOVE_FILES -eq 1 ]]; then
        local dest_dir="$(dirname "$src")/originals_bak"
        mkdir -p "$dest_dir" && mv -n "$src" "$dest_dir/" && {
            echo "源文件已移动至：$dest_dir/$(basename "$src")" | tee -a "$LOGFILE"
        }
    fi

    return $exit_status
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
    echo -e "\n工作目录：$(pwd)" | tee -a "$LOGFILE"

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
                find_cmd+=" -iname \"$pattern\""
            done
            find_cmd+=" \)"
        fi
        #        find_cmd+=" ! -name \"*-x265.*\" ! -name \"*-x264.*\" ! -name \"*-vp9.*\""
        find_cmd+=" ! -path \"*/originals_bak/*\""
        # 读取文件并过滤非视频格式
        file_array=()
        while IFS= read -r file; do
            # 获取文件扩展名并转换为小写
            local ext="${file##*.}"
            ext="${ext,,}"

            # 检查是否为支持的视频格式
            if [[ " ${SUPPORTED[FORMATS]} " =~ " $ext " ]]; then
                file_array+=("$file")
            else
                echo "跳过非视频文件: $file" | tee -a "$LOGFILE"
            fi
        done < <(eval "$find_cmd")
        # 显示找到的文件
        echo "执行查找命令：$find_cmd" | tee -a "$LOGFILE"
        echo "找到的文件列表：" | tee -a "$LOGFILE"
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

        # 新增：移动文件确认提示
        if [[ $MOVE_FILES -eq 0 && $SKIP_CONFIRM -eq 0 ]]; then
            read -p "是否将处理后的源文件移动到originals_bak文件夹？[y/N] " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && MOVE_FILES=1
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

        # 新增：移动文件确认提示
        if [[ $MOVE_FILES -eq 0 && $SKIP_CONFIRM -eq 0 ]]; then
            read -p "是否将处理后的源文件移动到originals_bak文件夹？[y/N] " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && MOVE_FILES=1
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
        fileNum=0
        echo "找到的文件列表：" | tee -a "$LOGFILE"
        shopt -s nocaseglob # 启用不区分大小写的通配符
        for fmt in "${FORMATS[@]}"; do
            for file in *."$fmt"; do
                if [[ -f "$file" ]]; then
                    echo "$file" | tee -a "$LOGFILE"
                    ((fileNum++))
                fi
            done
        done
        shopt -u nocaseglob

        # 用户确认
        if [[ $SKIP_CONFIRM -eq 0 ]]; then
            read -p "找到以上 $fileNum 个文件，是否继续处理？[y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && {
                echo "操作已取消" | tee -a "$LOGFILE"
                exit 0
            }
        fi

        # 新增：移动文件确认提示
        if [[ $MOVE_FILES -eq 0 && $SKIP_CONFIRM -eq 0 ]]; then
            read -p "是否将处理后的源文件移动到originals_bak文件夹？[y/N] " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] && MOVE_FILES=1
        fi

        # 新增：设置总文件数
        TOTAL_FILES=$fileNum

        # 处理文件
        shopt -s nocaseglob
        for fmt in "${FORMATS[@]}"; do
            for file in *."$fmt"; do
                [[ -f "$file" ]] || continue
                for enc in "${ENCODERS[@]}"; do
                    process_file "$file" "$enc"
                done
            done
        done
        shopt -u nocaseglob
    fi
    # 统计总耗时
    duration=$SECONDS

    # 输出详细统计
    if [[ ${#FILE_STATS[@]} -gt 0 ]]; then
        echo -e "==== 详细统计 ====" | tee -a "$LOGFILE"
        for log in "${FILE_STATS[@]}"; do
            echo -e "$log" | tee -a "$LOGFILE"
        done
    fi
    # 生成报告
    echo -e "\n==== 处理完成 ====" | tee -a "$LOGFILE"
    echo "已处理：    $PROCESSED/$TOTAL_FILES" | tee -a "$LOGFILE"
    echo "原始总量：  $(format_bytes $TOTAL_ORIGIN)" | tee -a "$LOGFILE"
    echo "压缩后总量：$(format_bytes $TOTAL_COMPRESSED)" | tee -a "$LOGFILE"
    echo "节省空间：  $(format_bytes $((TOTAL_ORIGIN - TOTAL_COMPRESSED)))" | tee -a "$LOGFILE"
    if [[ $TOTAL_ORIGIN -gt 0 ]]; then
        echo "压缩率：$(awk "BEGIN {printf \"%.2f\", ($TOTAL_ORIGIN - $TOTAL_COMPRESSED)/$TOTAL_ORIGIN*100}")%" | tee -a "$LOGFILE"
    fi
    # 输出总耗时
    echo -e "总耗时：$(($duration / 3600))小时$((($duration / 60) % 60))分钟$(($duration % 60))秒\n" | tee -a "$LOGFILE"
}

# trap 'echo "中断操作！"; exit 1' SIGINT
# 脚本入口
main "$@"
