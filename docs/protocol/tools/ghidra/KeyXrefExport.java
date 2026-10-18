// @category DJI
// 从 key 名字符串反向 xref 到引用函数，提取 (key_name, 函数, 常量集)
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import java.io.File;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class KeyXrefExport extends GhidraScript {

    private int exported = 0;

    @Override
    public void run() throws Exception {
        String outFile = "/Users/shiye/work/dji-research/key-xref.tsv";
        FileWriter map = new FileWriter(outFile);
        map.write("# key_name\tfunction_name\tfunction_addr\tconstants\n");

        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        Pattern constP = Pattern.compile("0x[0-9a-fA-F]{2,6}U?");

        // 1) 收集 key 模式字符串
        List<Data> keys = new ArrayList<>();
        DataIterator dit = currentProgram.getListing().getDefinedData(true);
        while (dit.hasNext()) {
            Data d = dit.next();
            if (monitor.isCancelled()) break;
            if (!d.hasStringValue()) continue;
            String v = d.getValue().toString();
            if (v.length() >= 8 && v.length() <= 64 && v.matches("[a-z][a-z0-9_]*")
                    && v.contains("_")) {
                keys.add(d);
            }
        }
        println("KEY_STRINGS=" + keys.size());

        // 2) 对每个 key 字符串，找引用函数并反编译
        int budget = 1200;
        for (Data d : keys) {
            if (exported >= budget || monitor.isCancelled()) break;
            String keyName = d.getValue().toString();
            LinkedHashSet<String> funcs = new LinkedHashSet<>();
            for (var r : getReferencesTo(d.getAddress())) {
                if (exported >= budget) break;
                Function f = getFunctionContaining(r.getFromAddress());
                if (f == null) continue;
                String fn = f.getName(true);
                if (!funcs.add(fn)) continue;
                try {
                    DecompileResults res = di.decompileFunction(f, 60, monitor);
                    if (res == null || !res.decompileCompleted()) continue;
                    String c = res.getDecompiledFunction().getC();
                    Matcher m = constP.matcher(c);
                    LinkedHashSet<String> nums = new LinkedHashSet<>();
                    while (m.find() && nums.size() < 8) {
                        String g = m.group().toLowerCase().replace("u", "");
                        long v = Long.decode(g);
                        if (v > 1 && v < 0x10000) nums.add(g);
                    }
                    map.write(keyName + "\t" + fn.substring(0, Math.min(fn.length(), 80))
                            + "\t" + Long.toHexString(f.getEntryPoint().getOffset())
                            + "\t" + String.join(",", nums) + "\n");
                    exported++;
                } catch (Exception e) { }
            }
        }
        map.close();
        println("KEYXREF_DONE=" + exported);
    }
}
