<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<header class="site-header">
    <div class="header-inner">
        <a href="/admin" class="brand">Zero Day Clinic Admin</a>
        <nav><a href="/admin">대시보드</a> <a href="/admin/users">회원 API</a> <a href="/logout">로그아웃</a></nav>
    </div>
</header>
<main>
    <section class="page-title">
        <p class="eyebrow">ADMIN</p>
        <h1>관리자 대시보드</h1>
        <p>고객 서비스와 분리된 관리자 전용 WAS에서 실행되는 화면입니다.</p>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="content-band admin-grid">
        <div class="panel">
            <h2>시술 상품 일괄 등록 (XML)</h2>
            <form action="/admin/procedures/import" method="post" enctype="multipart/form-data" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <input name="file" type="file" accept=".xml" required>
                <button class="button" type="submit">XML 등록</button>
            </form>
        </div>
        <div class="panel admin-procedure-panel">
            <h2>시술/상담 패키지 관리</h2>
            <#if procedures?has_content>
            <ul class="mini-list admin-procedure-list">
                <#list procedures as procedure>
                <li>
                    <div><strong>${procedure.name}</strong><span>${procedure.category} · ${numbers.formatInteger(procedure.price)}원</span></div>
                    <form action="/admin/procedures/${procedure.id}/delete" method="post" onsubmit="return confirm('이 패키지를 삭제하시겠습니까?');">
                        <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                        <button class="button button-danger button-small" type="submit">삭제</button>
                    </form>
                </li>
                </#list>
            </ul>
            <#else><p class="muted">등록된 시술/상담 패키지가 없습니다.</p></#if>
        </div>
        <div class="panel">
            <h2>최근 상담 신청</h2>
            <ul class="mini-list">
                <#list consultations as item>
                <li><strong>${item.name}</strong><span>${item.phone} · ${item.area} · ${item.preferredContact}<#if item.preferredDate??> · 희망일 ${temporals.format(item.preferredDate, 'yyyy.MM.dd')}</#if></span></li>
                </#list>
            </ul>
        </div>
        <div class="panel">
            <h2>최근 결제</h2>
            <ul class="mini-list">
                <#list orders as order>
                <li><strong>${order.orderNumber}</strong><span>${order.buyer.name} · ${order.procedureProduct.name} · ${numbers.formatInteger(order.amount)}원 · ${order.pointsUsed}P 사용</span></li>
                </#list>
            </ul>
        </div>
        <div class="panel">
            <h2>Q&A 답변 관리</h2>
            <ul class="mini-list">
                <#list qnas as post>
                <li><a href="/admin/qna/${post.id}">${post.title}</a><span>${post.answered?then('답변완료', '대기')}</span></li>
                </#list>
            </ul>
        </div>
    </section>
</main>
</body>
</html>
