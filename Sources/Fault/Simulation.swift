import Foundation
import Defile
import PythonKit

class Simulator {
    enum Behavior: Int {
        case holdHigh = 1
        case holdLow = 0
    }

    static func pseudoRandomVerilogGeneration(
        using testVector: TestVector,
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String, 
        ports: [String: Port],
        inputs: [Port],
        ignoring ignoredInputs: Set<String>,
        behavior: [Behavior],
        outputs: [Port],
        stuckAt: Int,
        delayFault: Bool,
        cleanUp: Bool,
        goldenOutput: Bool,
        clock: String?,
        filePrefix: String = ".",
        using iverilogExecutable: String,
        with vvpExecutable: String
    ) throws -> (faults: [String], goldenOutput: String) {
        var portWires = ""
        var portHooks = ""
        var portHooksGM = ""
        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name).gm ;\n"
            portHooks += ".\(name) ( \(name) ) , "
            portHooksGM += ".\(name) ( \(name).gm ) , "
        }

        let folderName = "\(filePrefix)/thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()

        var inputAssignment = ""
        var fmtString = ""
        var inputList = ""

        for (i, input) in inputs.enumerated() {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"

            inputAssignment += "        \(name) = \(testVector[i]) ;\n"
            inputAssignment += "        \(name).gm = \(name) ;\n"

            fmtString += "%d "
            inputList += "\(name) , "
        }

        for (i, rawName) in ignoredInputs.enumerated() {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"

            inputAssignment += "        \(name) = \(behavior[i].rawValue) ;\n"
            inputAssignment += "        \(name).gm = \(behavior[i].rawValue) ;\n"
        }

        fmtString = String(fmtString.dropLast(1))
        inputList = String(inputList.dropLast(2))

        var outputCount = 0 
        var outputComparison = ""
        var outputAssignment = ""
        for output in outputs {
            let name = (output.name.hasPrefix("\\")) ? output.name : "\\\(output.name)"
            outputComparison += " ( \(name) != \(name).gm ) || "
            if output.width > 1 {
                for i in 0..<output.width {
                    outputAssignment += "   assign goldenOutput[\(outputCount)] = gm.\(output.name)[\(i)] ; \n"
                    outputCount += 1
                }
            }
            else {
                outputAssignment += "   assign goldenOutput[\(outputCount)] = gm.\(name) ; \n"
                outputCount += 1
            }
        }
        outputComparison = String(outputComparison.dropLast(3))

        var faultForces = ""    
        for fault in faultPoints {
            faultForces += "        force uut.\(fault) = \(stuckAt) ; \n"
            faultForces += "        #2 ; \n"   
            faultForces += "        if (difference) $display(\"\(fault)\") ; \n"
            faultForces += "        #2 ; \n"
            faultForces += "        release uut.\(fault) ;\n"
            faultForces += "        #2 ; \n"

            if delayFault {
                faultForces += "        if(uut.\(fault) == \(stuckAt)) $display(\"v1: \(fault)\") ;\n"
                faultForces += "        #2 ; \n"
            }
        }

        var clockCreator = ""
        if let clockName = clock {
            clockCreator = "always #1 \(clockName) = ~\(clockName);"
        }

        let bench = """
        \(String.boilerplate)

        `include "\(cells)"
        `include "\(file)"

        module FaultTestbench;

        \(portWires)
            \(clockCreator)
            \(module) uut(
                \(portHooks.dropLast(2))
            );
            \(module) gm(
                \(portHooksGM.dropLast(2))
            );
           
            \(goldenOutput ?
            "wire [\(outputCount - 1):0] goldenOutput; \n \(outputAssignment)" : "")

            wire difference ;
            assign difference = (\(outputComparison));
            
            integer counter;

            initial begin
        \(inputAssignment)
        \(faultForces)
        \(goldenOutput ? "        $displayb(\"%b\", goldenOutput);": "" )
                $finish;
            end

        endmodule
        """;

        let tbName = "\(folderName)/tb.sv"
        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(folderName)/a.out"
        let intermediate = "\(folderName)/intermediate"
        let env = ProcessInfo.processInfo.environment
        let iverilogExecutable = env["FAULT_IVERILOG"] ?? "iverilog"
        let vvpExecutable = env["FAULT_VVP"] ?? "vvp"

        let iverilogResult =
            "'\(iverilogExecutable)' -B '\(iverilogBase)' -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
        if iverilogResult != EX_OK {
            exit(Int32(iverilogResult))
        }

        let vvpTask = "'\(vvpExecutable)' \(aoutName) > \(intermediate)".sh()
        if vvpTask != EX_OK {
            exit(vvpTask)
        }

        let output = File.read(intermediate)!
        defer {
            if cleanUp {
                let _ = "rm -rf \(folderName)".sh()
            }
        }

        var faults = output.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }

        let gmOutput = goldenOutput ? faults.removeLast() : ""
        return (faults: faults, goldenOutput: gmOutput)
    }

    static func simulate(
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        ignoring ignoredInputs: Set<String> = [],
        behavior: [Behavior] = [],
        outputs: [Port],
        initialVectorCount: Int,
        incrementingBy increment: Int,
        minimumCoverage: Float,
        ceiling: Int,
        randomGenerator: RNG,
        TVSet: [TestVector],
        sampleRun: Bool,
        clock: String?,
        using iverilogExecutable: String,
        with vvpExecutable: String
    ) throws -> (coverageList: [TVCPair], coverage: Float) {
        
        var testVectorHash: Set<TestVector> = []

        var coverageList: [TVCPair] = []
        var coverage: Float = 0.0

        var sa0Covered: Set<String> = []
        sa0Covered.reserveCapacity(faultPoints.count)
        var sa1Covered: Set<String> = []
        sa1Covered.reserveCapacity(faultPoints.count)

        var totalTVAttempts = 0
        var tvAttempts = (initialVectorCount < ceiling) ? initialVectorCount : ceiling
        
        let simulateOnly = (TVSet.count != 0)
        let rng: URNG = RNGFactory.shared().getRNG(type: randomGenerator)

        while coverage < minimumCoverage && totalTVAttempts < ceiling {
            if totalTVAttempts > 0 {
                print("Minimum coverage not met (\(coverage * 100)%/\(minimumCoverage * 100)%,) incrementing to \(totalTVAttempts + tvAttempts)…")
            }

            var futureList: [Future] = []
            var testVectors: [TestVector] = []
            for index in 0..<tvAttempts {
                var testVector: TestVector = []
                if (simulateOnly){
                    testVector = TVSet[totalTVAttempts + index]
                } else {
                    for input in inputs {
                        testVector.append(rng.generate(bits: input.width))
                    }
                }
                if testVectorHash.contains(testVector) {
                    continue
                }
                testVectorHash.insert(testVector)
                testVectors.append(testVector)
            }

            if testVectors.count < tvAttempts {
                print("Skipped \(tvAttempts - testVectors.count) duplicate generated test vectors.")
            }
            let tempDir = "\(NSTemporaryDirectory())"

            for vector in testVectors {
                let future = Future {
                    do {
                        let (sa0, output) =
                            try Simulator.pseudoRandomVerilogGeneration(
                                using: vector,
                                for: faultPoints,
                                in: file,
                                module: module,
                                with: cells,
                                ports: ports,
                                inputs: inputs,
                                ignoring: ignoredInputs,
                                behavior: behavior,
                                outputs: outputs,
                                stuckAt: 0,
                                delayFault: false,
                                cleanUp: !sampleRun,
                                goldenOutput: true,
                                clock: clock,
                                filePrefix: tempDir,
                                using: iverilogExecutable,
                                with: vvpExecutable
                            )

                        let (sa1, _) =
                            try Simulator.pseudoRandomVerilogGeneration(
                                using: vector,
                                for: faultPoints,
                                in: file,
                                module: module,
                                with: cells,
                                ports: ports,
                                inputs: inputs,
                                ignoring: ignoredInputs,
                                behavior: behavior,
                                outputs: outputs,
                                stuckAt: 1,
                                delayFault: false,
                                cleanUp: !sampleRun,
                                goldenOutput: true,
                                clock: clock,
                                filePrefix: tempDir,
                                using: iverilogExecutable,
                                with: vvpExecutable
                            )
                        
                        return (Covers: Coverage(sa0: sa0, sa1: sa1) , Output: output)
                    } catch {
                        print("IO Error @ vector \(vector)")
                        return (Covers: Coverage(sa0: [], sa1: []) , Output: "")
                    }
                }
                futureList.append(future)
                if sampleRun {
                    break
                }
            }

            for (i, future) in futureList.enumerated() {
                let (coverLists, output) = future.value as! (Coverage, String)
                for cover in coverLists.sa0 {
                    sa0Covered.insert(cover)
                }
                for cover in coverLists.sa1 {
                    sa1Covered.insert(cover)
                }
                coverageList.append(
                    TVCPair(
                        vector: testVectors[i],
                        coverage: coverLists,
                        goldenOutput: output
                    )
                )
            }

            coverage =
                Float(sa0Covered.count + sa1Covered.count) /
                Float(2 * faultPoints.count)
           
            totalTVAttempts += tvAttempts
            let remainingTV = ceiling - totalTVAttempts
            tvAttempts = (remainingTV < increment) ? remainingTV : increment
        }

        if coverage < minimumCoverage {
            print("Hit ceiling. Settling for current coverage.")
        }

        return (
            coverageList: coverageList,
            coverage: coverage
        )
    }

    enum Active {
        case low
        case high
    }

    static func simulate(
        verifying module: String,
        in file: String,
        isolated hard: String?,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        chainLength: Int,
        clock: String,
        tck: String,
        reset: String,
        sin: String,
        sout: String,
        resetActive: Active = .low,
        testing: String,
        clockDR: String,
        update: String,
        mode: String,
        output: String,
        using iverilogExecutable: String,
        with vvpExecutable: String
    ) throws -> Bool {

        var portWires = ""
        var portHooks = ""
        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portHooks += ".\(name) ( \(name) ) , "
        }

        var inputAssignment = ""
        for input in inputs {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"
            if input.name == reset {
                inputAssignment += "        \(name) = \( resetActive == .low ? 0 : 1 ) ;\n"
            } else {
                inputAssignment += "        \(name) = 0 ;\n"
            }
        }

        var serial = "0"
        for _ in 0..<chainLength-1 {
            serial += "\(Int.random(in: 0...1))"
        }

        var clockCreator = ""
        var tckCreator = ""
        if !clock.isEmpty {
            clockCreator = "always #1 \(clock) = ~\(clock);"
            tckCreator = "always #1 \(tck) = ~\(tck);"
        }
        var isolated = ""
        if let hardModule = hard {
            isolated = "`include \"\(hardModule)\""
        }

        let bench = """
        \(String.boilerplate)
        `include "\(cells)"
        `include "\(file)"
        \(isolated)
        module testbench;
        \(portWires)
            \(clockCreator)
            \(tckCreator)
            \(module) uut(
                \(portHooks.dropLast(2))
            );
            wire[\(chainLength - 1):0] serializable =
                \(chainLength)'b\(serial);
            reg[\(chainLength - 1):0] serial;
            integer i;
            initial begin
                $dumpfile("dut.vcd");
                $dumpvars(0, testbench);
        \(inputAssignment)
                #10;
                \(reset) = ~\(reset);
                \(testing) = 1;
                \(clockDR) = 1;
                \(update) = 1;
                \(mode) = 0;
                capture_1 = 1;  // Internal chains capture signals
                capture_2 = 1;

                for (i = 0; i < \(chainLength); i = i + 1) begin
                    \(sin) = serializable[i];
                    #2;
                end
                for (i = 0; i < \(chainLength); i = i + 1) begin
                    serial[i] = \(sout);
                    #2;
                end
                if (serial === serializable) begin
                    $display("SUCCESS_STRING");
                end
                $finish;
            end
        endmodule
        """

        try File.open(output, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(output).a.out"

        let iverilogResult =
            "'\(iverilogExecutable)' -B '\(iverilogBase)' -Ttyp -o \(aoutName) \(output) 2>&1 > /dev/null".shOutput()
        
        if iverilogResult.terminationStatus != EX_OK {
            fputs("An iverilog error has occurred: \n", stderr)
            fputs(iverilogResult.output, stderr)
            exit(Int32(iverilogResult.terminationStatus))
        }
        let vvpTask = "'\(vvpExecutable)' \(aoutName)".shOutput()

        if vvpTask.terminationStatus != EX_OK {
            throw "Failed to run vvp."
        }

        return vvpTask.output.contains("SUCCESS_STRING")
    }

    static func simulate(
        verifying module: String,
        in file: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        chains: [Chain],
        clock: String,
        reset: String,
        resetActive: Active = .low,
        tms: String,
        tdi: String,
        tck: String,
        tdo: String,
        trst: String,
        output: String,
        using iverilogExecutable: String,
        with vvpExecutable: String
    ) throws -> Bool {
        var success = true
        let tb = Testbench(
            ports: ports,
            inputs: inputs,
            clock: clock,
            reset: reset,
            resetActive: resetActive,
            in: file,
            with: cells
        )
        let boundaryChain = chains.filter{ $0.kind == .boundary }[0]
        let outputBoundaryCells = outputs.map{ $0.width }.reduce(0, +) - 1
        let boundaryBench = tb.createBoundary(
            chainLength: boundaryChain.length,
            outputBoundaryCount: outputBoundaryCells,
            inputs: inputs,
            outputs: outputs,
            tdi: tdi,
            tdo: tdo,
            tms: tms,
            tck: tck,
            trst: trst,
            clock: clock,
            reset: reset,
            module: module
        )
        success = try Testbench.run(bench: boundaryBench, output: "\(output)_1.sv")
        if success {
            print("Boundary Scan Chain verified successfuly.")
        }

        let internalChains = chains.filter { $0.kind != .boundary }
        let internalBench = tb.createInternal(
            chainLength: internalChains.map { $0.length },
            tdi: tdi,
            tdo: tdo,
            tms: tms,
            tck: tck,
            trst: trst,
            clock: clock,
            reset: reset,
            module: module
        )
        success = try Testbench.run(bench: internalBench, output: "\(output)_1.sv")
        if success {
            print("Internal Scan Chain verified successfuly.")
        }
       
        return success     
    }

    static func simulate(
        verifying module: String,
        in file: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        ignoring ignoredInputs: Set<String>,
        behavior: [Behavior],
        outputs: [Port],
        clock: String,
        reset: String,
        resetActive: Active = .low,
        tms: String,
        tdi: String,
        tck: String,
        tdo: String,
        trst: String,
        output: String,
        chains: [Chain],
        vecbinFile: String,
        outbinFile: String,
        vectorCount: Int, 
        vectorLength: Int,
        outputLength: Int,
        using iverilogExecutable: String,
        with vvpExecutable: String
    ) throws -> Bool {
    
        var portWires = ""
        var portHooks = ""
        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portHooks += ".\(name) ( \(name) ) , "
        }

        var inputAssignment = ""
        for (i, rawName) in ignoredInputs.enumerated() {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            inputAssignment += "        \(name) = \(behavior[i].rawValue) ;\n"
        }

        let tapPorts = [tck, trst, tdi]
        for input in inputs {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"
            if input.name == reset {
                inputAssignment += "        \(name) = \( resetActive == .low ? 0 : 1 ) ;\n"
            } else if input.name == tms {
                inputAssignment += "        \(name) = 1 ;\n"
            }
            else {
                inputAssignment += "        \(name) = 0 ;\n"
                if (input.name != clock && !tapPorts.contains(input.name)){
                }
            }
        }        
    
        var clockCreator = ""
        if !clock.isEmpty {
            clockCreator = "always #1 \(clock) = ~\(clock);"
        }
        var resetToggler = ""
        if !reset.isEmpty {
            resetToggler = "\(reset) = ~\(reset);"
        }
        var testStatements = ""
        for i in 0..<1 {  //vectorCount
            testStatements += "        test(vectors[\(i)], gmOutput[\(i)]) ;\n"
        }

        let boundaryOrder = chains.filter{ $0.kind == .boundary }[0]
        var boundaryOutput = 0
        var boundaryLength = 0
        for element in boundaryOrder.order {
            if element.kind != .output {
                boundaryLength += element.width
            } else {
                boundaryOutput += element.width
            }
        }

        let chainLength_1 =  chains.filter{ $0.kind != .boundary }[0].length
        let chainLength_2 =  chains.filter{ $0.kind != .boundary }[1].length

        print(boundaryLength)
        print(chainLength_1)
        print(chainLength_2)
        let bench = """
        \(String.boilerplate)
        `include "\(cells)"
        `include "\(file)"
        `include "Netlists/sram_1rw1r_32_256_8_sky130.v"
        module testbench;
        \(portWires)
            
            \(clockCreator)
            always #1 \(tck) = ~\(tck);

            \(module) uut(
                \(portHooks.dropLast(2))
            );

            integer i;

            reg [\(outputLength - 1):0] scanInSerial;
            reg [\(vectorLength - 1):0] vectors [0:\(vectorCount - 1)];
            reg [\(outputLength - 1):0] gmOutput[0:\(vectorCount - 1)];

            wire[7:0] tmsPattern = 8'b 01100110;
            wire[3:0] samplePreload = 4'b 0001;
            wire[3:0] preload_chain_1 = 4'b 0011;
            wire[3:0] preload_chain_2 = 4'b 0110;

            initial begin
                $dumpfile("dut.vcd"); // DEBUG
                $dumpvars(0, testbench);
        \(inputAssignment)
                $readmemb("\(vecbinFile)", vectors);
                $readmemb("\(outbinFile)", gmOutput);
                #50;
                \(resetToggler)
                \(trst) = 1;        
                #50;
        \(testStatements)
                $display("SUCCESS_STRING");
                $finish;
            end

            task test;
                input [\(vectorLength - 1):0] vector;
                input [\(outputLength - 1):0] goldenOutput;
                begin
                    // 1. Preload Boundary-Scan Chain
                    shiftIR(samplePreload);
                    enterShiftDR();

                    for (i = 0; i < \(boundaryLength); i = i + 1) begin
                        tdi = vector[\(vectorLength - boundaryLength) + i];
                        if(i == \(boundaryLength - 1)) begin
                            \(tms) = 1; // Exit-DR
                        end
                        #2;
                    end
                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    // 2. Preload Chain_1
                    ShiftIRToSelectDR(preload_chain_1);
                    \(tms) = 0;     // capture DR -- shift DR
                    #4;
                    for (i = 0; i < \(chainLength_1); i = i + 1) begin
                        tdi = vector[\(vectorLength - boundaryLength - chainLength_1) + i];
                        if(i == \(chainLength_1 - 1)) begin
                            \(tms) = 1; // Exit-DR
                        end
                        #2;
                    end

                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    // 3. Preload Chain_2
                    ShiftIRToSelectDR(preload_chain_2);
                    tms = 0;     // capture DR -- shift DR
                    #4;
                    for (i = 0; i < \(chainLength_2); i = i + 1) begin
                        tdi = vector[\(vectorLength - boundaryLength - chainLength_1 - chainLength_2) + i];
                        if(i == \(chainLength_2 - 1)) begin
                            \(tms) = 1; // Exit-DR
                        end
                        #2;
                    end

                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    // 4. Capture Response
                    /* Pending adjusting internal scan-chain */

                    // 5. Shift out Resonse

                    //  a) Shift-out from Boundary Chain
                    ShiftIRToSelectDR(samplePreload);
                    \(tms) = 0;     // capture DR -- shift DR
                    #4;
                    for (i = 0; i< \(boundaryOutput);i = i + 1) begin
                        #2;
                        \(tdi) = 0;
                        scanInSerial[i] = \(tdo);
                        if(i == \(boundaryOutput - 1)) begin
                            \(tms) = 1; // Exit-DR
                            #2;
                        end
                    end
                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    //  b) Shift-out from Internal Chain_1
                    ShiftIRToSelectDR(preload_chain_1);
                    \(tms) = 0;     // capture DR -- shift DR
                    #4;
                    for (i = 0; i < \(chainLength_1); i = i + 1) begin
                        #2;
                        \(tdi) = 0;
                        scanInSerial[i + \(boundaryOutput)] = \(tdo);
                        if(i == \(chainLength_1 - 1)) begin
                            \(tms) = 1; // Exit-DR
                            #2;
                        end
                    end
                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    // c) Shift-out from Internal Chain_2
                    ShiftIRToSelectDR(preload_chain_2);
                    \(tms) = 0;     // capture DR -- shift DR
                    #4;
                    for (i = 0; i < \(chainLength_2); i = i + 1) begin
                        #2;
                        \(tdi) = 0;
                        scanInSerial[i + \(boundaryOutput + chainLength_1)] = \(tdo);
                        if(i == \(chainLength_2 - 1)) begin
                            \(tms) = 1; // Exit-DR
                            #2;
                        end
                    end
                    \(tms) = 1; // update-DR
                    #2;
                    \(tms) = 1; // select-DR
                    #2;

                    if(scanInSerial !== goldenOutput) begin
                        $error("SIMULATING_TV_FAILED");
                        $finish;
                    end
                end
            endtask

            task ShiftIRToSelectDR;
                input[3:0] instruction;
                integer i;
                begin
                    \(tms) = 1; // select-IR
                    #2;
                    \(tms) = 0; // capture-IR
                    #2;
                    \(tms) = 0; // shift-IR
                    #2;
                    for (i = 0; i < 4; i = i + 1) begin
                        \(tdi) = instruction[i];
                        if(i == 3) begin
                            \(tms) = 1;     // exit-ir
                        end
                        #2;
                    end 
                    \(tms) = 1;     // update-ir 
                    #2;
                    \(tms) =1;     // select-DR
                    #2;
                end
            endtask

            task shiftIR;
                input[3:0] instruction;
                integer i;
                begin
                    for (i = 0; i< 5; i = i + 1) begin
                        \(tms) = tmsPattern[i];
                        #2;
                    end

                    // At shift-IR: shift new instruction on tdi line
                    for (i = 0; i < 4; i = i + 1) begin
                        tdi = instruction[i];
                        if(i == 3) begin
                            \(tms) = tmsPattern[5];     // exit-ir
                        end
                        #2;
                    end

                    \(tms) = tmsPattern[6];     // update-ir 
                    #2;
                    \(tms) = tmsPattern[7];     // run test-idle
                    #6;
                end
            endtask

            task enterShiftDR;
                begin
                    \(tms) = 1;     // select DR
                    #2;
                    \(tms) = 0;     // capture DR -- shift DR
                    #4;
                end
            endtask

            task exitDR;
                begin
                    \(tms) = 1;     // Exit DR -- update DR
                    #4;
                    \(tms) = 0;     // Run test-idle
                    #2;
                end
            endtask
        endmodule
        """

        let tbName = "\(output)"

        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(module).out"
        let iverilogResult =
            "'\(iverilogExecutable)' -B '\(iverilogBase)' -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".shOutput()
        
        if iverilogResult.terminationStatus != EX_OK {
            fputs("An iverilog error has occurred: \n", stderr)
            fputs(iverilogResult.output, stderr)
            exit(Int32(iverilogResult.terminationStatus))
        }
        let vvpTask = "'\(vvpExecutable)' \(aoutName)".shOutput()

        if vvpTask.terminationStatus != EX_OK {
            throw "Failed to run vvp."
        }

        return vvpTask.output.contains("SUCCESS_STRING")
    }
}
