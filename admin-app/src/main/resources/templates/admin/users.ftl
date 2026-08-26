<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>회원 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<header class="site-header">
    <div class="header-inner">
        <a href="/admin" class="brand">Zero Day Clinic Admin</a>
        <nav><a href="/admin">대시보드</a> <a href="/admin/users">회원 관리</a> <a href="/logout">로그아웃</a></nav>
    </div>
</header>
<main class="admin-users-page">
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">MEMBERS</p>
            <h1>회원 관리</h1>
            <p>회원 계정과 포인트 현황을 한눈에 확인할 수 있습니다.</p>
        </div>
        <a class="button button-outline" href="/api/admin/users">JSON API 보기</a>
    </section>

    <section class="content-band admin-user-summary" aria-label="회원 요약">
        <article>
            <span>전체 회원</span>
            <strong>${users?size}</strong>
            <small>registered accounts</small>
        </article>
        <article>
            <span>관리자</span>
            <strong>${adminCount}</strong>
            <small>admin role</small>
        </article>
        <article>
            <span>일반 회원</span>
            <strong>${userCount}</strong>
            <small>user role</small>
        </article>
        <article>
            <span>총 보유 포인트</span>
            <strong>${numbers.formatInteger(totalPointBalance)}</strong>
            <small>point balance</small>
        </article>
    </section>

    <section class="content-band admin-user-panel">
        <div class="section-head">
            <h2>회원 목록</h2>
            <span class="muted">${users?size}명</span>
        </div>
        <#if users?has_content>
        <div class="admin-user-table-wrap">
            <table class="admin-user-table">
                <thead>
                <tr>
                    <th scope="col">회원</th>
                    <th scope="col">권한</th>
                    <th scope="col">연락처</th>
                    <th scope="col">포인트</th>
                    <th scope="col">가입일</th>
                </tr>
                </thead>
                <tbody>
                <#list users as user>
                <tr>
                    <td>
                        <div class="admin-user-profile">
                            <span><#if user.name?has_content>${user.name?substring(0, 1)}<#else>U</#if></span>
                            <div>
                                <strong>${user.name}</strong>
                                <small>@${user.username} · ID ${user.id}</small>
                            </div>
                        </div>
                    </td>
                    <td><span class="role-badge role-${user.role?string?lower_case}">${user.role}</span></td>
                    <td>
                        <div class="admin-user-contact">
                            <strong>${user.email!'-'}</strong>
                            <small>${user.phone!'-'}</small>
                        </div>
                    </td>
                    <td><strong class="point-balance">${numbers.formatInteger(user.pointBalance)}P</strong></td>
                    <td><time>${temporals.format(user.createdAt, 'yyyy.MM.dd')}</time></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>등록된 회원이 없습니다.</strong>
            <p>회원이 가입하면 이곳에 표시됩니다.</p>
        </div>
        </#if>
    </section>
</main>
</body>
</html>
