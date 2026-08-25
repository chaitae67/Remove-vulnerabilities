<header class="site-header">
    <a class="brand" href="/">
        <img class="brand-logo" src="/images/zero-day-clinic-logo.svg" alt="제로데이클리닉 로고">
        <span>
            <strong>제로데이클리닉</strong>
            <small>ZERO DAY CLINIC</small>
        </span>
    </a>
    <nav class="main-nav">
        <a href="/procedures">시술/패키지</a>
        <a href="/reviews">이용후기</a>
        <a href="/qna">온라인상담</a>
        <a href="/notices">공지사항</a>
        <#if isAdmin><a href="/admin">관리자</a></#if>
    </nav>
    <div class="auth-nav">
        <#if !isAuthenticated>
        <a href="/login">로그인</a>
        <a class="button button-outline" href="/register">회원가입</a>
        </#if>
        <#if isAuthenticated>
        <a class="hello" href="/mypage?userId=${currentUserId}">${currentUsername}</a>
        <form action="/logout" method="post">
            <button class="link-button" type="submit">로그아웃</button>
        </form>
        </#if>
    </div>
</header>
