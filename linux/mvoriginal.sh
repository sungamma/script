#!/bin/bash

# 创建目标目录（当前目录下的 originals_bak）
mkdir -p "./originals_bak"

# 查找当前目录下所有含 -x265 的文件
find . -maxdepth 1 -type f -name "*-x265*" -print0 | while IFS= read -r -d '' file; do
    # 获取文件名（不含路径）
    filename=$(basename "$file")

    # 生成原始文件名（删除 -x265 部分）
    originals_bakal_filename=$(echo "$filename" | sed 's/-x265//')

    # 检查当前目录下的原始文件是否存在
    if [[ -f "./$originals_bakal_filename" ]]; then
        # 构建目标路径
        dest_path="./originals_bak/${originals_bakal_filename}"

        # 检测目标路径是否已存在
        if [[ -f "$dest_path" ]]; then
            echo "[提示] 文件 $originals_bakal_filename 已存在于 originals_bak 目录，跳过移动"
        else
            echo -n "移动: $originals_bakal_filename → originals_bak/ ... "
            if mv -- "./$originals_bakal_filename" "./originals_bak/"; then
                echo "成功"
            else
                echo "失败"
            fi
        fi
    else
        echo "[提示] 原始文件 $originals_bakal_filename 不存在，跳过"
    fi
done

echo "操作完成"
