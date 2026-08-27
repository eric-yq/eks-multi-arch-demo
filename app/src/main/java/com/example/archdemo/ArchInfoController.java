package com.example.archdemo;

import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 架构信息接口：
 * <ul>
 *   <li>{@code GET /}          纯文本，适合 curl / 浏览器快速查看</li>
 *   <li>{@code GET /api/info}  JSON，适合脚本统计 x86 与 Graviton 的分布</li>
 * </ul>
 */
@RestController
public class ArchInfoController {

    private final ArchInfoService archInfoService;

    public ArchInfoController(ArchInfoService archInfoService) {
        this.archInfoService = archInfoService;
    }

    @GetMapping(value = "/", produces = MediaType.TEXT_PLAIN_VALUE + ";charset=UTF-8")
    public String home() {
        Map<String, Object> info = archInfoService.info();
        @SuppressWarnings("unchecked")
        Map<String, Object> k8s = (Map<String, Object>) info.get("kubernetes");
        @SuppressWarnings("unchecked")
        Map<String, Object> jvm = (Map<String, Object>) info.get("jvm");
        @SuppressWarnings("unchecked")
        Map<String, Object> resources = (Map<String, Object>) info.get("resources");

        return """
               EKS multi-arch Java demo
               ------------------------------------------
               CPU 架构 (os.arch) : %s
               平台               : %s
               vCPU 可见数        : %s
               JVM                : %s %s
               最大堆 (MB)        : %s
               Pod                : %s
               Node               : %s
               节点组             : %s
               实例类型           : %s
               ------------------------------------------
               更多信息: /api/info | 压测: /api/bench?iterations=2000000
               """.formatted(
                       ((Map<?, ?>) info.get("architecture")).get("osArch"),
                       ((Map<?, ?>) info.get("architecture")).get("platform"),
                       resources.get("availableProcessors"),
                       jvm.get("vmName"),
                       jvm.get("javaVersion"),
                       resources.get("maxHeapMB"),
                       k8s.get("podName"),
                       k8s.get("nodeName"),
                       k8s.get("nodeGroup"),
                       k8s.get("nodeInstanceType"));
    }

    @GetMapping(value = "/api/info", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> info() {
        return archInfoService.info();
    }
}
