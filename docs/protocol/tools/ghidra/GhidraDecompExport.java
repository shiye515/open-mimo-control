// Ghidra headless script: 批量导出 DJI 协议关键函数的反编译 C 代码
// @category DJI
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import java.io.File;
import java.io.FileWriter;
import java.util.HashMap;
import java.util.Map;

public class GhidraDecompExport extends GhidraScript {

    private static final String[] KEYWORDS = {
        "UpdateAppShootPhotoButtonPressed", "StartRecordAction", "StopRecordAction",
        "SetSendPackParam", "OnSendV1", "OnRecvV1Data", "bridge_send_data",
        "update_app_shootphoto", "PackProviderImpl", "SetPackInfo", "ConfigHostID",
        "SendActionPack", "SendDataWithTcpPort", "SendData", "calc_crc", "verify_crc",
        "dji_cmd_req", "GlobalPacketStatus", "SwitchComPort",
        "send_data", "pack_data", "PackData", "cmd_id", "encode_pack", "EncodePack",
        "build_frame", "BuildFrame", "make_packet", "MakePacket",
        "Udp_Send_Addr", "Udp_Create", "socket_send_data", "UdpSocketForVideo"
    };
    private static final int MAX_PER = 10;

    private long exported = 0;

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
                exported++;
                println("Exported[" + tag + "]: " + f.getName(true));
            }
        } catch (Exception e) {
            println("Failed[" + tag + "]: " + e.getMessage());
        }
    }

    @Override
    public void run() throws Exception {
        String outDir = "/Users/shiye/work/dji-research/decompiled";
        new File(outDir).mkdirs();

        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);

        // 1) xref 到 CRC 函数的调用者（帧构造点）—— 反汇编扫描 bl 目标
        FunctionIterator it0 = currentProgram.getFunctionManager().getFunctions(true);
        Map<Long, java.util.List<Function>> crcCallers = new HashMap<>();
        while (it0.hasNext()) {
            Function f = it0.next();
            String n = f.getName();
            if (n.equals("calc_crc16") || n.equals("calc_crc8") || n.equals("calc_crc16_ex")
                    || n.equals("verify_crc16_cheksum")) {
                crcCallers.put(f.getEntryPoint().getOffset(), new java.util.ArrayList<Function>());
            }
        }
        if (!crcCallers.isEmpty()) {
            // 扫描全部指令找 bl 到 CRC 函数（用 getInstructions 流）
            ghidra.program.model.listing.InstructionIterator iit =
                currentProgram.getListing().getInstructions(true);
            while (iit.hasNext()) {
                ghidra.program.model.listing.Instruction ins = iit.next();
                if (!ins.getMnemonicString().equals("b") && !ins.getMnemonicString().equals("bl")) continue;
                ghidra.program.model.address.Address[] flows = ins.getFlows();
                for (ghidra.program.model.address.Address a : flows) {
                    java.util.List<Function> lst = crcCallers.get(a.getOffset());
                    if (lst != null && lst.size() < 15) {
                        Function caller = getFunctionContaining(ins.getAddress());
                        if (caller != null && !lst.contains(caller)) {
                            lst.add(caller);
                        }
                    }
                }
            }
            for (Map.Entry<Long, java.util.List<Function>> e : crcCallers.entrySet()) {
                for (Function c : e.getValue()) {
                    decompileTo(c, di, "CRCXREF_" + Long.toHexString(e.getKey()));
                }
            }
        }

        // 2) 关键词匹配导出
        Map<String, Integer> perKw = new HashMap<>();
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext()) {
            Function f = it.next();
            String name = f.getName(true);
            for (String kw : KEYWORDS) {
                Integer n = perKw.get(kw);
                if (name.contains(kw) && (n == null || n < MAX_PER)) {
                    perKw.put(kw, n == null ? 1 : n + 1);
                    decompileTo(f, di, "KW");
                    break;
                }
            }
        }
        println("TOTAL_EXPORTED=" + exported);
    }
}
