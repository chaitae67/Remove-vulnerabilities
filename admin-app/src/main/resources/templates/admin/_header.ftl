<#-- 관리자 화면 공통 헤더. 각 페이지에서 <#assign navActive = "..."> 로 현재 메뉴를 표시한다. -->
<header class="site-header">
    <div class="header-inner">
        <a href="/admin" class="brand">Zero Day Clinic Admin</a>
        <nav class="admin-nav">
            <a href="/admin"<#if (navActive!'') == 'dashboard'> class="active"</#if>>대시보드</a>
            <a href="/admin/consultations"<#if (navActive!'') == 'consultations'> class="active"</#if>>상담 신청</a>
            <a href="/admin/payments"<#if (navActive!'') == 'payments'> class="active"</#if>>결제 관리</a>
            <a href="/admin/users"<#if (navActive!'') == 'users'> class="active"</#if>>회원 관리</a>
            <a href="/admin/procedures"<#if (navActive!'') == 'procedures'> class="active"</#if>>시술 관리</a>
            <a href="/admin/notices"<#if (navActive!'') == 'notices'> class="active"</#if>>공지사항</a>
            <a href="/admin/coupons"<#if (navActive!'') == 'coupons'> class="active"</#if>>쿠폰 관리</a>
            <a href="/admin/records"<#if (navActive!'') == 'records'> class="active"</#if>>의무기록</a>
            <a href="/admin/qna"<#if (navActive!'') == 'qna'> class="active"</#if>>Q&amp;A</a>
            <#-- CF-07: 로그아웃은 CSRF 토큰을 포함한 POST로만 처리한다. -->
            <form action="/logout" method="post" class="logout-form" style="display:inline">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <button type="submit" class="link-button">로그아웃</button>
            </form>
        </nav>
    </div>
</header>
<#-- XS-06: 플래시 메시지에 사용자 입력(파일명 등)이 포함될 수 있으므로 이스케이프한다. -->
<#if message??><div class="flash success">${message?html}</div></#if>
<#if error??><div class="flash error">${error?html}</div></#if>
