// @category DJI
// 枚举所有 Send/Observer 模板实例，反编译并提取 cmd 立即数 → 生成 cmd↔功能映射表
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import java.io.File;
import java.io.FileWriter;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class CmdMapExport extends GhidraScript {

    private static final String[] TEMPLATE_MARKERS = {
        "SendGetPack", "SendActionPack", "SendParamGet", "SendSetPack",
        "ObserverPushPack", "ObserverGetPack", "SendSet", "SendGet",
        "SendAction", "ObserverPack", "PushPack", "SendSubscribe",
        "SendObserverPack", "SendDataPack"
    };

    @Override
    public void run() throws Exception {
        String outFile = "/Users/shiye/work/dji-research/cmd-map.tsv";
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);

        FileWriter map = new FileWriter(outFile);
        map.write("# cmd_candidate(s)\treq_type\tfunction_addr\n");

        Pattern hexP = Pattern.compile("0x[0-9a-fA-F]{3,8}");
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        int done = 0, decompiled = 0;
        while (it.hasNext()) {
            Function f = it.next();
            String name = f.getName(true);
            String marker = null;
            for (String m : TEMPLATE_MARKERS) {
                if (name.contains(m)) { marker = m; break; }
            }
            if (marker == null) continue;

            // 模板参数类型名（mangled 名里类型明文可见：如 13wifi_stop_req）
            String type = "";
            java.util.regex.Matcher tm = Pattern.compile("I[0-9N]*(?:[0-9]+[a-zA-Z_0-9]+)+E").matcher(name);
            if (tm.find()) {
                type = tm.group().replaceAll("^[IN0-9]+|E$", "").replaceAll("[0-9]{1,3}", " ").trim();
                type = type.replace(' ', '_');
            } else {
                java.util.regex.Matcher rm = Pattern.compile("[a-z][a-z_0-9]+_(?:req|rsp|push)").matcher(name);
                if (rm.find()) type = rm.group();
            }

            try {
                DecompileResults res = di.decompileFunction(f, 120, monitor);
                decompiled++;
                if (res != null && res.decompileCompleted()) {
                    String c = res.getDecompiledFunction().getC();
                    // 收集所有 0x100-0xFFFF 十六进制常量（按出现顺序，去重）
                    Matcher m = hexP.matcher(c);
                    StringBuilder cands = new StringBuilder();
                    java.util.LinkedHashSet<String> seen = new java.util.LinkedHashSet<>();
                    while (m.find() && seen.size() < 6) {
                        long v = Long.decode(m.group());
                        if (v >= 0x100 && v <= 0xFFFF) {
                            seen.add(String.format("0x%04x", v));
                        }
                    }
                    for (String s : seen) {
                        if (cands.length() > 0) cands.append(",");
                        cands.append(s);
                    }
                    map.write(cands + "\t" + type + "\t" + Long.toHexString(f.getEntryPoint().getOffset()) + "\n");
                    done++;
                }
            } catch (Exception e) {
                // skip
            }
            if (monitor.isCancelled()) break;
        }
        map.close();
        println("TEMPLATES_DONE=" + done + " DECOMPILED=" + decompiled);
    }
}
