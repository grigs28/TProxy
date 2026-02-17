/**
 * Proxy Manager - 主应用逻辑
 */

const API_BASE = '';
const AUTH_TOKEN = 'Basic admin:admin';

// 创建 Vue 应用
const { createApp } = Vue;

createApp({
    data() {
        return {
            // 状态数据
            status: {
                containers: { dnsmasq: {}, tengine: {} },
                nginx: {},
                cache_size: '0B',
                disk: {},
                system: {}
            },
            // 配置数据
            config: {},
            // 配置模板
            configTemplate: null,
            // 配置分组
            configGroups: {
                network: { name: '网络配置', icon: '🌐' },
                ports: { name: '端口配置', icon: '🔌' },
                cache: { name: '缓存配置', icon: '💾' },
                nginx: { name: 'Nginx 性能', icon: '⚡' },
                proxy: { name: '代理配置', icon: '🔀' },
                dns: { name: 'DNS 配置', icon: '🔍' },
                security: { name: '安全配置', icon: '🔒' },
                system: { name: '系统配置', icon: '⚙️' }
            },
            // 系统服务状态
            systemStatus: {
                enabled: false,
                active: 'unknown'
            },
            // 当前激活的配置分组
            activeConfigGroup: 'network',
            // DNS 配置
            dnsContent: '',
            // Hosts Master 配置
            hostsMasterContent: '',
            hostsMasterStats: null,
            // 日志
            logs: '点击上方按钮查看日志...',
            currentLog: '',
            // UI 状态
            loading: false,
            showClearCacheModal: false,
            showRestartModal: false,
            currentTab: 'overview',
            // 刷新定时器
            refreshTimer: null,
            // 部署状态
            deployStatus: {
                deploying: false,
                status: {
                    step: '',
                    progress: 0,
                    message: '',
                    error: null
                }
            },
            // 部署状态轮询定时器
            deployPollTimer: null,
            // 日志自动刷新定时器
            logRefreshTimer: null
        };
    },

    computed: {
        // 容器状态样式
        generatorStatusClass() {
            return this.status.containers['proxy-generator']?.status || 'unknown';
        },
        dnsmasqStatusClass() {
            return this.status.containers.dnsmasq?.status || 'unknown';
        },
        tengineStatusClass() {
            return this.status.containers.tengine?.status || 'unknown';
        },
        // 系统健康状态
        systemHealth() {
            const generator = this.status.containers['proxy-generator']?.status;
            const dnsmasq = this.status.containers.dnsmasq?.status;
            const tengine = this.status.containers.tengine?.status;
            if (generator === 'running' && dnsmasq === 'running' && tengine === 'running') return 'healthy';
            if (generator === 'running' || dnsmasq === 'running' || tengine === 'running') return 'warning';
            return 'error';
        }
    },

    mounted() {
        this.init();
    },

    beforeUnmount() {
        if (this.refreshTimer) {
            clearInterval(this.refreshTimer);
        }
        if (this.deployPollTimer) {
            clearInterval(this.deployPollTimer);
        }
        if (this.logRefreshTimer) {
            clearInterval(this.logRefreshTimer);
        }
    },

    methods: {
        // 初始化
        async init() {
            await this.fetchAllData();
            // 每 5 秒刷新状态
            this.refreshTimer = setInterval(() => {
                this.fetchStatus();
            }, 5000);
        },

        // 获取所有数据
        async fetchAllData() {
            await Promise.all([
                this.fetchStatus(),
                this.fetchConfig(),
                this.fetchConfigTemplate(),
                this.fetchDns(),
                this.fetchSystemStatus(),
                this.fetchHostsMaster()
            ]);
        },

        // 获取系统服务状态
        async fetchSystemStatus() {
            try {
                const res = await axios.get(`${API_BASE}/api/system/status`);
                this.systemStatus = res.data;
            } catch (e) {
                console.error('获取系统状态失败:', e);
            }
        },

        // 获取状态
        async fetchStatus() {
            try {
                const res = await axios.get(`${API_BASE}/api/status`);
                this.status = res.data;
            } catch (e) {
                console.error('获取状态失败:', e);
            }
        },

        // 获取配置
        async fetchConfig() {
            try {
                const res = await axios.get(`${API_BASE}/api/config`);
                this.config = res.data;
            } catch (e) {
                console.error('获取配置失败:', e);
            }
        },

        // 获取配置模板
        async fetchConfigTemplate() {
            try {
                const res = await axios.get(`${API_BASE}/api/config/template`);
                this.configTemplate = res.data;
            } catch (e) {
                console.error('获取配置模板失败:', e);
            }
        },

        // 获取 DNS 配置
        async fetchDns() {
            try {
                const res = await axios.get(`${API_BASE}/api/dns/hosts`);
                this.dnsContent = res.data.content || '';
            } catch (e) {
                console.error('获取 DNS 配置失败:', e);
            }
        },

        // 保存配置
        async saveConfig() {
            // 先验证配置（检查端口等）
            try {
                const validateRes = await axios.post(`${API_BASE}/api/config/validate`, this.config, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });

                if (!validateRes.data.valid) {
                    // 显示验证错误
                    let errorMsg = '配置验证失败:\n\n';
                    if (validateRes.data.errors && validateRes.data.errors.length > 0) {
                        errorMsg += validateRes.data.errors.join('\n');
                    }
                    if (validateRes.data.port_conflicts && validateRes.data.port_conflicts.length > 0) {
                        errorMsg += '\n\n端口冲突:\n';
                        validateRes.data.port_conflicts.forEach(c => {
                            errorMsg += `  - ${c.port}/${c.proto} 被 ${c.process} (PID: ${c.pid}) 占用\n`;
                        });
                    }

                    // 询问是否强制保存
                    const forceSave = confirm(
                        errorMsg + '\n\n是否要强制保存配置？（可能导致服务无法启动）'
                    );

                    if (!forceSave) {
                        return;
                    }
                }

                // 保存配置
                const res = await axios.post(`${API_BASE}/api/config`, this.config, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });

                // 显示保存结果和警告
                let message = res.data.message || '配置已保存，需重启容器生效';

                // 显示警告信息
                if (validateRes.data.warnings && validateRes.data.warnings.length > 0) {
                    message += '\n\n警告:\n' + validateRes.data.warnings.join('\n');
                }

                // 处理 AUTO_START 配置
                const autoStart = this.config.AUTO_START;
                if (autoStart !== undefined) {
                    const enable = autoStart === 'true';
                    const currentEnabled = this.systemStatus.enabled;

                    // 如果要禁用服务，且当前服务正在运行，需要确认
                    if (!enable && currentEnabled) {
                        const confirmDisable = confirm(
                            '⚠️ 禁用开机自启将同时停止 Proxy Manager 服务！\n\n' +
                            '保存后 Web 界面将无法访问，需要手动启动服务。\n\n' +
                            '确定要继续吗？'
                        );
                        if (!confirmDisable) {
                            return;  // 用户取消
                        }
                    }

                    try {
                        const autoRes = await axios.post(`${API_BASE}/api/system/autostart`,
                            { enable },
                            { headers: { 'Authorization': AUTH_TOKEN } }
                        );
                        message += '\n\n' + autoRes.data.message;

                        // 如果禁用了服务，显示额外提示
                        if (!enable) {
                            message += '\n\n⚠️ Web 界面将在几秒后无法访问。';
                            message += '\n如需重新启动，请使用命令：';
                            message += '\n   systemctl start proxy-manager';

                            // 禁用后延迟刷新状态（避免服务已停止导致请求失败）
                            setTimeout(() => this.fetchSystemStatus(), 500);
                        } else {
                            await this.fetchSystemStatus();
                        }
                    } catch (e) {
                        message += '\n\n设置开机自启失败: ' + (e.response?.data?.error || e.message);
                    }
                }

                // 处理 PROXY_MANAGER_PORT 变更（需要提示用户重启服务）
                if (validateRes.data.warnings && validateRes.data.warnings.some(w => w.includes('管理程序端口'))) {
                    message += '\n\n⚠️ 管理程序端口已变更，请手动重启 Proxy Manager 服务使新端口生效。';
                    message += '\n   或点击下方"重启管理程序"按钮。';
                }

                this.notify('success', message);

            } catch (e) {
                this.notify('error', '保存失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 重启 Proxy Manager 服务
        async restartProxyManager() {
            if (!confirm('重启 Proxy Manager 服务后，Web 界面将暂时无法访问。\n\n确定要重启吗？')) {
                return;
            }

            // 切换到日志标签页并显示提示
            this.currentTab = 'logs';
            this.logs = '⏳ 服务正在重启，请在 5-10 秒后刷新页面查看日志...\n\n' +
                      '重启日志将在服务恢复后自动加载。';

            try {
                // 发送重启请求（不等待响应，因为服务会重启）
                const res = await axios.post(`${API_BASE}/api/system/restart`, {}, {
                    headers: { 'Authorization': AUTH_TOKEN },
                    timeout: 5000  // 5 秒超时
                });

                // 请求成功，延迟后开始获取日志
                setTimeout(async () => {
                    try {
                        // 尝试获取 proxy-manager 日志
                        await this.fetchLogs('proxy-manager');
                        // 启动自动刷新（每 5 秒一次，持续 1 分钟）
                        let retryCount = 0;
                        this.logRefreshTimer = setInterval(async () => {
                            await this.fetchLogs('proxy-manager');
                            retryCount++;
                            if (retryCount >= 12) { // 12 * 5 = 60 秒
                                clearInterval(this.logRefreshTimer);
                                this.logRefreshTimer = null;
                            }
                        }, 5000);
                    } catch (e) {
                        // 忽略错误，继续尝试
                        this.logs += '\n\n等待服务恢复...';
                    }
                }, 8000);

            } catch (e) {
                // 即使请求失败（服务已重启），也继续等待日志
                if (e.code === 'ECONNABORTED' || e.message.includes('Network Error')) {
                    // 请求超时或网络错误是正常的，说明服务正在重启
                    setTimeout(async () => {
                        try {
                            await this.fetchLogs('proxy-manager');
                            let retryCount = 0;
                            this.logRefreshTimer = setInterval(async () => {
                                await this.fetchLogs('proxy-manager');
                                retryCount++;
                                if (retryCount >= 12) {
                                    clearInterval(this.logRefreshTimer);
                                    this.logRefreshTimer = null;
                                }
                            }, 5000);
                        } catch (e2) {
                            this.logs += '\n\n等待服务恢复...';
                        }
                    }, 8000);
                } else {
                    this.logs = '重启失败: ' + (e.response?.data?.error || e.message);
                }
            }
        },

        // 一键部署
        async startDeploy() {
            if (this.deployStatus.deploying) {
                return;
            }

            if (!confirm('⚠️ 一键部署将：\n\n' +
                '1. 停止所有容器\n' +
                '2. 重新构建 Tengine 镜像（5-10分钟）\n' +
                '3. 启动所有服务\n\n' +
                '确定要开始部署吗？')) {
                return;
            }

            try {
                const res = await axios.post(`${API_BASE}/api/deploy`, {}, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });

                if (res.data.success) {
                    this.deployStatus.deploying = true;
                    this.startDeployPolling();
                    this.notify('success', '部署任务已启动');
                    // 自动切换到日志标签并显示部署日志
                    this.currentTab = 'logs';
                    this.fetchLogs('deploy');
                } else {
                    this.notify('error', res.data.error || '部署启动失败');
                }
            } catch (e) {
                this.notify('error', '部署失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 开始轮询部署状态
        startDeployPolling() {
            if (this.deployPollTimer) {
                clearInterval(this.deployPollTimer);
            }

            this.deployPollTimer = setInterval(async () => {
                try {
                    const res = await axios.get(`${API_BASE}/api/deploy/status`);
                    const data = res.data;

                    this.deployStatus.deploying = data.deploying;
                    this.deployStatus.status = data.status;

                    // 部署完成或失败，停止轮询
                    if (!data.deploying) {
                        clearInterval(this.deployPollTimer);
                        this.deployPollTimer = null;

                        if (data.status.error) {
                            this.notify('error', '部署失败: ' + data.status.error);
                        } else if (data.status.step === 'complete') {
                            this.notify('success', '🎉 部署完成！');
                            // 刷新容器状态
                            setTimeout(() => this.fetchStatus(), 2000);
                        }
                    }
                } catch (e) {
                    console.error('获取部署状态失败:', e);
                }
            }, 2000); // 每 2 秒轮询一次
        },

        // 保存 DNS 配置
        async saveDns() {
            try {
                const res = await axios.post(`${API_BASE}/api/dns/hosts`,
                    { content: this.dnsContent },
                    { headers: { 'Authorization': AUTH_TOKEN } }
                );
                this.notify('success', res.data.message || 'DNS 解析已更新');
            } catch (e) {
                this.notify('error', '保存失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 获取 hosts-master.txt 配置
        async fetchHostsMaster() {
            try {
                const res = await axios.get(`${API_BASE}/api/hosts-master`);
                this.hostsMasterContent = res.data.content || '';
                this.calculateHostsStats();
            } catch (e) {
                console.error('获取 hosts-master.txt 失败:', e);
                // 如果文件不存在，使用默认内容
                this.hostsMasterContent = `; TProxy hosts-master.txt 配置文件
; 格式说明:
;   ; @category <类别>     - 缓存分类 (docker/yum/pypi/github/other)
;   ; @cache <过期时间>    - 缓存时间 (30d, 7d, 1h)
;   ; @real-ip <IP:端口>  - 源站真实地址
;   ; @nocache            - 禁用缓存
;   address=/域名/代理IP   - 域名解析规则

; ========================================
; Docker 镜像加速
; ========================================
; @category docker
; @cache 30d
; @real-ip 54.236.113.205:443
address=/docker.io/192.168.0.36
address=/registry-1.docker.io/192.168.0.36
address=/production.cloudflare.docker.com/192.168.0.36

; ========================================
; PyPI 镜像加速
; ========================================
; @category pypi
; @cache 7d
address=/pypi.org/192.168.0.36

; ========================================
; YUM 源加速
; ========================================
; @category yum
; @cache 1d
address=/repo.openeuler.org/192.168.0.36

; ========================================
; GitHub 加速
; ========================================
; @category github
; @cache 7d
address=/github.com/192.168.0.36
address=/api.github.com/192.168.0.36
`;
                this.calculateHostsStats();
            }
        },

        // 保存 hosts-master.txt 配置
        async saveHostsMaster() {
            try {
                const res = await axios.post(`${API_BASE}/api/hosts-master`,
                    { content: this.hostsMasterContent },
                    { headers: { 'Authorization': AUTH_TOKEN } }
                );
                this.notify('success', res.data.message || 'hosts-master.txt 已保存');
                this.calculateHostsStats();
            } catch (e) {
                this.notify('error', '保存失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 计算 hosts-master.txt 统计信息
        calculateHostsStats() {
            const stats = {
                total: 0,
                docker: 0,
                yum: 0,
                pypi: 0,
                github: 0,
                other: 0
            };

            const lines = this.hostsMasterContent.split('\n');
            let currentCategory = 'other';

            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed || trimmed.startsWith('#')) continue;

                // 检查类别标记
                if (trimmed.startsWith('; @category ')) {
                    const category = trimmed.substring(12).trim();
                    if (['docker', 'yum', 'pypi', 'github', 'other'].includes(category)) {
                        currentCategory = category;
                    }
                    continue;
                }

                // 统计 address 规则
                if (trimmed.startsWith('address=/')) {
                    stats.total++;
                    stats[currentCategory]++;
                }
            }

            this.hostsMasterStats = stats;
        },

        // 重载 Nginx
        async reloadNginx() {
            try {
                const res = await axios.post(`${API_BASE}/api/nginx/reload`, {}, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });
                this.notify('success', res.data.message || 'Nginx 已重载');
            } catch (e) {
                this.notify('error', '重载失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 重启容器
        async restartContainer(name) {
            try {
                const res = await axios.post(`${API_BASE}/api/container/${name}/restart`, {}, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });
                this.notify('success', res.data.message || `${name} 已重启`);
                this.showRestartModal = false;
                // 延迟刷新状态
                setTimeout(() => this.fetchStatus(), 2000);
            } catch (e) {
                this.notify('error', '重启失败: ' + (e.response?.data?.error || e.message));
            }
        },

        // 获取日志
        async fetchLogs(service) {
            this.currentLog = service;

            // 清除之前的日志刷新定时器
            if (this.logRefreshTimer) {
                clearInterval(this.logRefreshTimer);
                this.logRefreshTimer = null;
            }

            try {
                const res = await axios.get(`${API_BASE}/api/logs/${service}`);
                this.logs = res.data.logs || '暂无日志';

                // 如果是部署日志且正在部署，自动刷新
                if (service === 'deploy' && this.deployStatus.deploying) {
                    this.logRefreshTimer = setInterval(() => {
                        this.fetchLogs(service);
                    }, 3000); // 每 3 秒刷新一次
                }
            } catch (e) {
                this.logs = '获取日志失败: ' + (e.response?.data?.error || e.message);
            }
        },

        // 清理缓存
        async clearCache(type) {
            try {
                const res = await axios.post(`${API_BASE}/api/cache/clear`, { type }, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });
                this.notify('success', res.data.message || '缓存已清理');
                this.showClearCacheModal = false;
                this.fetchStatus();
            } catch (e) {
                this.notify('error', '清理失败');
            }
        },

        // 通知提示
        notify(type, message) {
            const icon = type === 'success' ? '✅' : '❌';
            alert(`${icon} ${message}`);
        },

        // 切换 Tab
        switchTab(tab) {
            this.currentTab = tab;
        },

        // 格式化时间
        formatTime(isoString) {
            if (!isoString) return '-';
            return new Date(isoString).toLocaleString('zh-CN');
        },

        // 获取状态图标
        getStatusIcon(status) {
            const icons = {
                running: '✓',
                stopped: '✕',
                unknown: '?',
                error: '!',
                not_found: '◐',
                restarting: '↻'
            };
            return icons[status] || '?';
        },

        // 获取状态文本
        getStatusText(status) {
            const texts = {
                running: '运行中',
                stopped: '已停止',
                unknown: '未知',
                error: '错误',
                not_found: '未找到',
                restarting: '重启中'
            };
            return texts[status] || status;
        },

        // 获取容器状态样式类
        getContainerStatusClass(name) {
            return this.status.containers[name]?.status || 'unknown';
        },

        // 系统测试
        async runSystemTest() {
            try {
                const res = await axios.post(`${API_BASE}/api/test`, {}, {
                    headers: { 'Authorization': AUTH_TOKEN }
                });

                if (res.data.success) {
                    const results = res.data.results;
                    let report = '🧪 系统测试报告\n';
                    report += '='.repeat(50) + '\n\n';

                    // 端口监听测试
                    report += '📡 端口监听测试:\n';
                    report += `  DNS 端口 (53):      ${results.ports.dns ? '✅ 正常' : '❌ 未监听'}\n`;
                    report += `  代理端口 (3128):    ${results.ports.proxy ? '✅ 正常' : '❌ 未监听'}\n`;
                    report += `  状态页端口 (8080):  ${results.ports.status ? '✅ 正常' : '❌ 未监听'}\n\n`;

                    // DNS 解析测试
                    report += '🔍 DNS 解析测试:\n';
                    if (results.dns.baidu) {
                        report += `  www.baidu.com: ✅ 解析成功\n`;
                        if (results.dns.output) {
                            report += `  解析结果: ${results.dns.output}\n`;
                        }
                    } else {
                        report += `  www.baidu.com: ❌ 解析失败\n`;
                        if (results.dns.output) {
                            report += `  错误信息: ${results.dns.output}\n`;
                        }
                    }
                    report += '\n';

                    // 代理功能测试
                    report += '🔄 代理功能测试:\n';
                    if (results.proxy.success) {
                        report += `  HTTP 代理: ✅ 正常工作\n`;
                        // 显示前几行输出
                        if (results.proxy.output) {
                            const lines = results.proxy.output.split('\n').slice(0, 3).join('\n');
                            report += `  响应头:\n${lines}\n`;
                        }
                    } else {
                        report += `  HTTP 代理: ❌ 测试失败\n`;
                        if (results.proxy.output) {
                            report += `  错误信息: ${results.proxy.output}\n`;
                        }
                    }

                    alert(report);
                } else {
                    this.notify('error', '测试失败: ' + (res.data.error || '未知错误'));
                }
            } catch (e) {
                this.notify('error', '测试请求失败: ' + (e.response?.data?.error || e.message));
            }
        }
    }
}).mount('#app');
