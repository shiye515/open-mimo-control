// @category DJI
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;
import java.io.File;
import java.io.FileWriter;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

public class SearchImmCmd extends GhidraScript {

    private long[] TARGETS;

    private void decompileTo(Function f, DecompInterface di, String tag) {
        try {
            DecompileResults res = di.decompileFunction(f, 180, monitor);
            if (res != null && res.decompileCompleted()) {
                String c = res.getDecompiledFunction().getC();
                String safe = f.getName().replaceAll("[^A-Za-z0-9_]", "_");
                if (safe.length() > 90) safe = safe.substring(0, 90);
                File out = new File("/Users/shiye/work/dji-research/decompiled",
                        tag + "_" + safe + "_" + Long.toHexString(f.getEntryPoint().getOffset()) + ".c");
                FileWriter w = new FileWriter(out);
                w.write("// " + f.getName(true) + "\n");
                w.write(c);
                w.close();
                println("Exported[" + tag + "]: " + f.getName(true));
            }
        } catch (Exception e) {
            println("Failed: " + e.getMessage());
        }
    }

    @Override
    public void run() throws Exception {
        // 目标立即数从 args 传入，逗号分隔；默认轮询 cmd 0x2fee
        String arg = getScriptArgs().length > 0 ? getScriptArgs()[0] : "0x2fee";
        String[] parts = arg.split(",");
        TARGETS = new long[parts.length];
        Set<Long> targets = new HashSet<>();
        for (int i = 0; i < parts.length; i++) {
            TARGETS[i] = Long.decode(parts[i].trim());
            targets.add(TARGETS[i]);
        }

        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);

        Map<Long, Function> hits = new HashMap<>();
        InstructionIterator it = currentProgram.getListing().getInstructions(true);
        int scanned = 0;
        while (it.hasNext()) {
            Instruction ins = it.next();
            scanned++;
            int nops = ins.getNumOperands();
            for (int oi = 0; oi < nops; oi++) {
                Object[] ops = ins.getOpObjects(oi);
                for (Object o : ops) {
                    if (o instanceof Scalar) {
                        long v = ((Scalar) o).getUnsignedValue();
                        // 匹配目标或其字节交换/高移形式
                        if (targets.contains(v) || targets.contains(v & 0xFFFF)
                                || targets.contains((v >> 16) & 0xFFFF) || targets.contains(v >> 8 & 0xFFFF)) {
                            Function f = getFunctionContaining(ins.getAddress());
                            if (f != null) {
                                hits.put(f.getEntryPoint().getOffset(), f);
                            }
                            oi = nops;
                            break;
                        }
                    }
                }
            }
        }
        println("SCANNED=" + scanned + " HIT_FUNCS=" + hits.size());
        for (Function f : hits.values()) {
            println("HIT: " + f.getName(true) + " @ " + f.getEntryPoint());
            decompileTo(f, di, "CMDIMM");
        }
    }
}
