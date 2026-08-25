<header class="site-header">
    <a class="brand" href="/">
        <span class="brand-mark">TL</span>
        <span>
            <strong>탑라인 성형외과</strong>
            <small>Plastic Surgery Clinic</small>
        </span>
    </a>
    <nav class="main-nav">
        <a href="/procedures">시술/패키지</a>
        <a href="/reviews">이용후기</a>
        <a href="/qna">온라인상담</a>
        <a href="/notices">공지사항</a>
        <#if isAdmin>
        <a href="/admin">관리자</a>
        </#if>
    </nav>
    <div class="auth-nav">
        <#if isAuthenticated>
        <a class="hello" href="/mypage?userId=${currentUserId}">${currentUsername}</a>
        <form action="/logout" method="post">
            <button class="link-button" type="submit">로그아웃</button>
        </form>
        <#else>
        <a href="/login">로그인</a>
        <a class="button button-outline" href="/register">회원가입</a>
        </#if>
    </div>
</header>
