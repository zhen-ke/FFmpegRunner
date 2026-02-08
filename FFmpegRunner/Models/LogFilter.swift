//
//  LogFilter.swift
//  FFmpegRunner
//
//  日志过滤级别
//

import Foundation

/// 日志过滤级别
enum LogFilter: String, CaseIterable {
    case all = "全部"
    case important = "仅错误/警告"
    case noDebug = "隐藏 Debug"
}
