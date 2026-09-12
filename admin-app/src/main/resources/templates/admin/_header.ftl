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
            <a href="/logout">로그아웃</a>
        </nav>
    </div>
</header>
<#if message??><div class="flash success">${message}</div></#if>
<#if error??><div class="flash error">${error}</div></#if>
