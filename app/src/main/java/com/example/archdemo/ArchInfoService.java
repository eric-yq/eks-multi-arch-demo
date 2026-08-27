package com.example.archdemo;

import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * 收集运行时架构信息（CPU 架构、JVM、容器与 Kubernetes 上下文）。
 */
@Service
public class ArchInfoService {

    private final String appName;
    private final String appVersion;

    public ArchInfoService(@Value("${spring.application.name:java-arch-demo}") String appName,
                           @Value("${demo.version:1.0.0}") String appVersion) {
        this.appName = appName;
        this.appVersion = appVersion;
    }

    /** JVM 上报的 os.arch：x86_64 上为 amd64，Graviton/ARM 上为 aarch64。 */
    public String osArch() {
        return System.getProperty("os.arch", "unknown");
    }

    /** 归一化后的架构名，便于前端与脚本判断。 */
    public String normalizedArch() {
        String arch = osArch().toLowerCase();
        if (arch.contains("aarch64") || arch.contains("arm64")) {
            return "arm64";
        }
        if (arch.contains("amd64") || arch.contains("x86_64")) {
            return "amd64";
        }
        return arch;
    }

    /** 人类可读的平台描述。 */
    public String platformLabel() {
        return "arm64".equals(normalizedArch())
                ? "AWS Graviton (aarch64)"
                : "x86_64 (Intel/AMD)";
    }

    public Map<String, Object> info() {
        Runtime runtime = Runtime.getRuntime();
        long mb = 1024L * 1024L;

        Map<String, Object> app = new LinkedHashMap<>();
        app.put("name", appName);
        app.put("version", appVersion);
        app.put("timestamp", Instant.now().toString());

        Map<String, Object> arch = new LinkedHashMap<>();
        arch.put("osArch", osArch());
        arch.put("normalizedArch", normalizedArch());
        arch.put("platform", platformLabel());
        arch.put("osName", System.getProperty("os.name"));
        arch.put("osVersion", System.getProperty("os.version"));

        Map<String, Object> jvm = new LinkedHashMap<>();
        jvm.put("javaVersion", System.getProperty("java.version"));
        jvm.put("javaVendor", System.getProperty("java.vendor"));
        jvm.put("vmName", System.getProperty("java.vm.name"));
        jvm.put("vmVersion", System.getProperty("java.vm.version"));
        jvm.put("uptimeSeconds", ManagementFactory.getRuntimeMXBean().getUptime() / 1000);

        Map<String, Object> resources = new LinkedHashMap<>();
        resources.put("availableProcessors", runtime.availableProcessors());
        resources.put("maxHeapMB", runtime.maxMemory() / mb);
        resources.put("totalHeapMB", runtime.totalMemory() / mb);
        resources.put("freeHeapMB", runtime.freeMemory() / mb);

        Map<String, Object> kubernetes = new LinkedHashMap<>();
        kubernetes.put("podName", env("POD_NAME"));
        kubernetes.put("podIP", env("POD_IP"));
        kubernetes.put("namespace", env("POD_NAMESPACE"));
        kubernetes.put("nodeName", env("NODE_NAME"));
        kubernetes.put("nodeGroup", env("NODE_GROUP"));
        kubernetes.put("nodeInstanceType", env("NODE_INSTANCE_TYPE"));
        kubernetes.put("hostname", hostname());

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("app", app);
        result.put("architecture", arch);
        result.put("jvm", jvm);
        result.put("resources", resources);
        result.put("kubernetes", kubernetes);
        return result;
    }

    private static String env(String key) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? "n/a" : value;
    }

    private static String hostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return env("HOSTNAME");
        }
    }
}
