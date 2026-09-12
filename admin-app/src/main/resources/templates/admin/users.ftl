<#assign navActive = "users">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>회원 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-users-page">
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">MEMBERS</p>
            <h1>회원 관리</h1>
            <p>회원 계정과 포인트 현황을 한눈에 확인할 수 있습니다.</p>
        </div>
        <form class="admin-search" action="/admin/users" method="get">
            <input name="keyword" type="search" placeholder="아이디 · 이름 · 이메일 · 연락처" value="${(keyword!'')?html}">
            <button class="button button-small" type="submit">회원 찾기</button>
        </form>
    </section>

    <section class="content-band admin-user-summary" aria-label="회원 요약">
        <article>
            <span>전체 회원</span>
            <strong>${totalCount}</strong>
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
            <span class="muted">${users?size}명<#if keyword?has_content> · '${keyword?html}' 검색 결과</#if></span>
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
                    <th scope="col"><span class="sr-only">상세</span></th>
                </tr>
                </thead>
                <tbody>
                <#list users as user>
                <tr data-href="/admin/users/${user.id}">
                    <td>
                        <div class="admin-user-profile">
                            <span><#if user.name?has_content>${user.name?substring(0, 1)?html}<#else>U</#if></span>
                            <div>
                                <strong><a class="cell-link" href="/admin/users/${user.id}">${user.name?html}</a></strong>
                                <small>@${user.username?html} · ID ${user.id}</small>
                            </div>
                        </div>
                    </td>
                    <td><span class="role-badge role-${user.role?string?lower_case}">${user.role}</span></td>
                    <td>
                        <div class="admin-user-contact">
                            <strong>${(user.email!'-')?html}</strong>
                            <small>${(user.phone!'-')?html}</small>
                        </div>
                    </td>
                    <td><strong class="point-balance">${numbers.formatInteger(user.pointBalance)}P</strong></td>
                    <td><time>${temporals.format(user.createdAt, 'yyyy.MM.dd')}</time></td>
                    <td class="cell-action"><a href="/admin/users/${user.id}">상세 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong><#if keyword?has_content>검색 결과가 없습니다.<#else>등록된 회원이 없습니다.</#if></strong>
            <p><#if keyword?has_content>다른 검색어로 다시 시도해 보세요.<#else>회원이 가입하면 이곳에 표시됩니다.</#if></p>
        </div>
        </#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
</body>
</html>
