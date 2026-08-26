(() => {
    const toggle = document.getElementById('chatbot-toggle');
    const panel = document.getElementById('chatbot-panel');
    const close = document.getElementById('chatbot-close');
    const form = document.getElementById('chatbot-form');
    const input = document.getElementById('chatbot-input');
    const messages = document.getElementById('chatbot-messages');

    if (!toggle || !panel || !form || !input || !messages) {
        return;
    }

    function setOpen(open) {
        panel.hidden = !open;
        toggle.setAttribute('aria-expanded', String(open));
        if (open) {
            input.focus();
        }
    }

    function appendMessage(text, type, renderHtml = false) {
        const message = document.createElement('div');
        message.className = `chatbot-message ${type}`;
        if (renderHtml) {
            // VULNERABLE LAB: 서버 답변을 정화하지 않고 HTML로 렌더링해 반사형 XSS가 가능하다.
            message.innerHTML = text;
        } else {
            message.textContent = text;
        }
        messages.appendChild(message);
        messages.scrollTop = messages.scrollHeight;
        return message;
    }

    function formatAssistantAnswer(rawAnswer) {
        const normalized = String(rawAnswer || '')
            .replace(/\r/g, '')
            .trim();

        // 모델이 이미 HTML을 반환했다면 그대로 사용한다.
        if (/<\/?(?:p|div|span|ul|ol|li|strong|em|br)\b/i.test(normalized)) {
            return normalized.replace(/\n+/g, ' ');
        }

        const lines = normalized.split('\n');
        const html = [];
        let listItems = [];

        const flushList = () => {
            if (listItems.length) {
                html.push(`<ul>${listItems.map(item => `<li>${item}</li>`).join('')}</ul>`);
                listItems = [];
            }
        };

        lines.forEach(line => {
            const compact = line.trim().replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
            const listMatch = compact.match(/^(?:[-*•]|\d+\.)\s+(.+)$/);
            if (listMatch) {
                listItems.push(listMatch[1]);
                return;
            }
            flushList();
            if (compact) {
                html.push(`<p>${compact}</p>`);
            }
        });
        flushList();

        return html.join('');
    }

    async function sendMessage(question) {
        appendMessage(question, 'user');
        const loading = appendMessage('답변을 확인하고 있습니다...', 'bot loading');
        input.disabled = true;

        try {
            const headers = {'Content-Type': 'application/json'};
            const csrfToken = panel.dataset.csrfToken;
            const csrfHeader = panel.dataset.csrfHeader;
            if (csrfToken && csrfHeader) {
                headers[csrfHeader] = csrfToken;
            }

            const response = await fetch('/api/chat', {
                method: 'POST',
                headers,
                body: JSON.stringify({message: question})
            });
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }

            const data = await response.json();
            // VULNERABLE LAB: ChatbotService가 질문을 그대로 반사한 응답을 HTML로 해석한다.
            const formattedAnswer = formatAssistantAnswer(data.answer);
            const modeLabel = data.mode === 'AI'
                ? '<small class="chatbot-mode">AI 답변</small>'
                : data.mode === 'GUIDE'
                    ? '<small class="chatbot-mode">빠른 안내</small>'
                    : '<small class="chatbot-mode fallback">기본 안내 · Ollama 연결 안 됨</small>';
            loading.innerHTML = `${modeLabel}${formattedAnswer}`;
            loading.classList.remove('loading');
        } catch (error) {
            loading.textContent = '일시적으로 답변을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.';
            loading.classList.remove('loading');
        } finally {
            input.disabled = false;
            input.focus();
        }
    }

    toggle.addEventListener('click', () => setOpen(panel.hidden));
    close.addEventListener('click', () => setOpen(false));
    form.addEventListener('submit', event => {
        event.preventDefault();
        const question = input.value.trim();
        if (!question) {
            return;
        }
        input.value = '';
        sendMessage(question);
    });
    document.querySelectorAll('[data-chat-question]').forEach(button => {
        button.addEventListener('click', () => sendMessage(button.dataset.chatQuestion));
    });
})();
