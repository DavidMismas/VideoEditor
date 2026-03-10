import Foundation

nonisolated enum TransferFunctions {
    
    // MARK: - Rec.709
    
    static func rec709ToLinear(_ x: Double) -> Double {
        if x < 0.081 {
            return x / 4.5
        }
        return pow((x + 0.099) / 1.099, 1.0 / 0.45)
    }
    
    static func linearToRec709(_ x: Double) -> Double {
        if x < 0.018 {
            return x * 4.5
        }
        return 1.099 * pow(x, 0.45) - 0.099
    }

    // MARK: - sRGB / Display P3

    static func sRGBToLinear(_ x: Double) -> Double {
        if x <= 0.04045 {
            return x / 12.92
        }
        return pow((x + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ x: Double) -> Double {
        if x <= 0.0031308 {
            return x * 12.92
        }
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
    
    // MARK: - Apple Log
    
    static func appleLogToLinear(_ x: Double) -> Double {
        let r0 = -0.05641088
        let rt = 0.01
        let c  = 47.28711236
        let b  = 0.00964052
        let y  = 0.08550479
        let d  = 0.69336945
        let threshold = c * pow(rt - r0, 2.0)
        
        if x >= threshold {
            return exp2((x - d) / y) - b
        } else if x > 0.0 {
            return pow(x / c, 0.5) + r0
        } else {
            return r0
        }
    }

    static func linearToAppleLog(_ x: Double) -> Double {
        let r0 = -0.05641088
        let rt = 0.01
        let c  = 47.28711236
        let b  = 0.00964052
        let y  = 0.08550479
        let d  = 0.69336945

        if x >= rt {
            return (log2(x + b) * y) + d
        } else if x > r0 {
            return c * pow(x - r0, 2.0)
        } else {
            return 0.0
        }
    }
    
    // MARK: - Sony S-Log2 / S-Log3
    
    static func sonySLog2ToLinear(_ x: Double) -> Double {
        let b = 0.03000122285188
        let c = 0.011536
        let linear = (pow(10.0, ((x * 1023.0 - 128.0) / 90.0) / 0.432699) - b) / c
        return linear
    }

    static func sonySLog3ToLinear(_ x: Double) -> Double {
        if x >= 0.1710526315789 {
            return pow(10.0, (x - 0.410557184752) / 0.255555555555)
        }
        return (x - 0.0928641975309) / 5.36622415132
    }
    
    // MARK: - Panasonic V-Log
    
    static func panasonicVLogToLinear(_ x: Double) -> Double {
        let c = 0.241514
        let b = 0.00873
        let d = 0.598206
        let cut1 = 0.181
        if x < cut1 {
            return (x - 0.125) / 5.6
        }
        return pow(10.0, (x - d) / c) - b
    }
    
    // MARK: - DJI D-Log
    
    static func djiDLogToLinear(_ x: Double) -> Double {
        if x <= 0.14 {
            return (x - 0.0929) / 6.025
        }
        return pow(10.0, (x - 0.385537) / 0.2471896)
    }
    
    // MARK: - ARRI LogC3 / LogC4
    
    static func arriLogC3ToLinear(_ x: Double) -> Double {
        let cut = 0.1496582
        let a = 5.555556
        let b = 0.052272
        let c = 0.247190
        let d = 0.385537
        let e = 5.367655
        let f = 0.092809
        if x > cut {
            return (pow(10.0, (x - d) / c) - b) / a
        }
        return (x - f) / e / a
    }
    
    static func arriLogC4ToLinear(_ t: Double) -> Double {
        let a = (pow(2.0, 18.0) - 16.0) / 117.45
        let b = (1023.0 - 95.0) / 1023.0
        let c = 95.0 / 1023.0
        let s = (7.0 * log(2.0) * pow(2.0, 7.0 - 14.0)) / (a * b)
        let t_s = (pow(2.0, 14.0) - 16.0) / 117.45
        
        let normalized = (t - c) / b
        if normalized < t_s {
            return (normalized - t_s) / s
        }
        return (pow(2.0, 14.0 * normalized + 4.0) - 16.0) / 117.45
    }
    // MARK: - Canon Log
    
    static func canonLogToLinear(_ x: Double) -> Double {
        let max_ire = 10.1596
        let linear = pow(10.0, (x - 0.529136) / 0.253614) - 0.0730593
        return linear / max_ire
    }
    
    static func canonLog2ToLinear(_ x: Double) -> Double {
        let max_ire = 82.2312
        var linear: Double
        if x < 0.035388 {
            linear = (x - 0.035388) / 3.99628
        } else {
            linear = (pow(10.0, (x - 0.432324) / 0.274381) - 0.0465223) / max_ire
        }
        return linear
    }
    
    static func canonLog3ToLinear(_ x: Double) -> Double {
        let d = 0.0730597
        let c = 0.24136
        let b = 0.529136
        
        if x < 0.030588 {
            return (x - 0.0730597) / 10.1596 // Rough approx for Canon Log3 shadow segment
        } else {
            return pow(10.0, (x - b) / c) - d
        }
    }
    
    // MARK: - Fujifilm F-Log
    
    static func fujiFLogToLinear(_ x: Double) -> Double {
        let a = 0.555556
        let b = 0.009468
        let c = 0.344676
        let d = 0.125
        let f = 0.048737
        let cut = 0.09139
        
        if x < cut {
            return (x - f) / a
        } else {
            return pow(10.0, (x - c) / d) - b
        }
    }
    
    static func fujiFLog2ToLinear(_ x: Double) -> Double {
        let a = 5.555556
        let b = 0.031535
        let c = 0.203613
        let d = 0.092809
        let e = 5.367655
        let cut = 0.1006866
        
        if x < cut {
            return (x - d) / e
        } else {
            return pow(10.0, (x - b) / c) - a
        }
    }
}
