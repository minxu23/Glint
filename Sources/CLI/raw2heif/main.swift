// raw2heif：把相机 RAW 按系统默认显影转成 10 位 HEIF，RAW 原片永远保留。
// 流程全在 Run.swift，与 jpeg2heif 共用。

runCommandLine(.raw2heif)
