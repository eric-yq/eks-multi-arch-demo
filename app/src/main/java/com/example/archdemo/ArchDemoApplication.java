package com.example.archdemo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * 多架构 Java demo 入口。
 *
 * <p>同一个 jar 包（架构无关的字节码）会被打进 amd64 / arm64 两种镜像，
 * 通过 {@code /api/info} 可以直接看到当前 Pod 实际运行在哪种 CPU 架构上。
 */
@SpringBootApplication
public class ArchDemoApplication {

    public static void main(String[] args) {
        SpringApplication.run(ArchDemoApplication.class, args);
    }
}
