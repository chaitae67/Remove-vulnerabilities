<#assign navActive = "users">
<#import "/admin/_macros.ftl" as fmt>
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>회원 상세 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">MEMBER #${user.id}</p>
        <h1>${user.name?html} <span class="role-badge role-${user.role?string?lower_case}">${user.role}</span></h1>
        <p><a class="back-link" href="/admin/users">← 회원 목록</a></p>
    </section>

    <section class="content-band admin-detail-grid">
        <div class="panel">
            <h2>회원 정보 수정</h2>
            <form action="/admin/users/${user.id}" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>아이디<input value="${user.username?html}" disabled></label>
                <label>이름<input name="name" value="${user.name?html}" required></label>
                <label>이메일<input name="email" type="email" value="${user.email?html}" required></label>
                <label>연락처<input name="phone" value="${(user.phone!'')?html}"></label>
                <label>포인트 잔액<input name="pointBalance" type="number" min="0" step="1" value="${user.pointBalance?c}" required></label>
                <div class="form-actions">
                    <button class="button" type="submit">저장</button>
                </div>
            </form>

            <div class="role-form">
                <h2>권한 관리</h2>
                <p class="muted">직원 계정에 관리자 권한을 부여하면 이 관리자 페이지에 로그인할 수 있습니다.</p>
                <form action="/admin/users/${user.id}/role" method="post" class="stack-form">
                    <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                    <label>권한
                        <select name="role">
                            <option value="USER"<#if user.role?string == 'USER'> selected</#if>>USER (일반 회원)</option>
                            <option value="ADMIN"<#if user.role?string == 'ADMIN'> selected</#if>>ADMIN (관리자)</option>
                        </select>
                    </label>
                    <div class="form-actions">
                        <button class="button button-outline" type="submit">권한 변경</button>
                    </div>
                </form>
            </div>
        </div>

        <aside class="panel">
            <h2>계정 현황</h2>
            <dl class="summary-list">
                <div><dt>아이디</dt><dd>@${user.username?html}</dd></div>
                <div><dt>이메일</dt><dd>${user.email?html}</dd></div>
                <div><dt>연락처</dt><dd>${(user.phone!'-')?html}</dd></div>
                <div><dt>포인트</dt><dd><strong class="point-balance">${numbers.formatInteger(user.pointBalance)}P</strong></dd></div>
                <div><dt>가입일</dt><dd>${temporals.format(user.createdAt, 'yyyy.MM.dd')}</dd></div>
                <div><dt>상태</dt><dd>${user.withdrawn?then('탈퇴', '이용중')}</dd></div>
            </dl>

            <h2>결제 내역</h2>
            <#if orders?has_content>
            <ul class="mini-list">
                <#list orders as order>
                <li>
                    <a href="/admin/payments/${order.id}">${order.orderNumber?html}</a>
                    <span>${order.procedureProduct.name?html} · ${numbers.formatInteger(order.amount)}원 · ${fmt.statusLabel(order.status?string)}</span>
                </li>
                </#list>
            </ul>
            <#else>
            <p class="muted">결제 내역이 없습니다.</p>
            </#if>
        </aside>
    </section>
</main>
</body>
</html>
