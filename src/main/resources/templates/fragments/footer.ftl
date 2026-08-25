<footer class="site-footer">
    <div>
        <strong>제로데이클리닉</strong>
        <p>경기도 성남시 분당구 판교로227번길 23 | 대표번호 010-9268-8539</p>
    </div>
    <p class="medical-note">수술 및 시술 후 출혈, 감염, 염증 등의 합병증이 발생할 수 있으며 결과와 만족도는 개인에 따라 다를 수 있습니다. 온라인 상담은 진료를 대체하지 않습니다.</p>
</footer>

<button id="chatbot-toggle" class="chatbot-toggle" type="button" aria-expanded="false" aria-controls="chatbot-panel">
    상담 챗봇
</button>
<section id="chatbot-panel" class="chatbot-panel" aria-label="상담 챗봇" hidden>
    <header class="chatbot-header">
        <div>
                <strong>제로데이클리닉 안내 챗봇</strong>
            <span>병원 이용 정보를 안내해 드려요.</span>
        </div>
        <button id="chatbot-close" type="button" aria-label="챗봇 닫기">×</button>
    </header>
    <div id="chatbot-messages" class="chatbot-messages" aria-live="polite">
        <p class="chatbot-message bot">안녕하세요. AI 챗봇입니다. 시술 가격, 상담, 포인트 또는 공지사항에 대해 물어보세요.</p>
    </div>
    <div class="chatbot-quick-actions" aria-label="빠른 질문">
        <button type="button" data-chat-question="시술 가격 알려줘">시술 가격</button>
        <button type="button" data-chat-question="상담은 어떻게 신청해?">상담 신청</button>
        <button type="button" data-chat-question="포인트 사용 방법 알려줘">포인트</button>
    </div>
    <form id="chatbot-form" class="chatbot-form">
        <label class="sr-only" for="chatbot-input">질문 입력</label>
        <input id="chatbot-input" maxlength="500" placeholder="질문을 입력하세요" autocomplete="off" required>
        <button type="submit">전송</button>
    </form>
    <p class="chatbot-disclaimer">챗봇 안내는 의료진의 진료를 대체하지 않습니다.</p>
</section>
<script src="/js/chatbot.js"></script>
