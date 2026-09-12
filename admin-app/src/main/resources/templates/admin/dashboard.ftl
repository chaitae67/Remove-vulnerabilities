<#assign navActive = "dashboard">
<#import "/admin/_macros.ftl" as fmt>
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main>
    <section class="page-title">
        <p class="eyebrow">ADMIN</p>
        <h1>관리자 대시보드</h1>
        <p>고객 서비스와 분리된 관리자 전용 WAS에서 실행되는 화면입니다.</p>
    </section>
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
            <div class="section-head">
                <h2>시술/상담 패키지 관리</h2>
                <a href="/admin/procedures">전체 보기 · 가격 수정 &rsaquo;</a>
            </div>
            <#if procedures?has_content>
            <ul class="mini-list admin-procedure-list">
                <#list procedures as procedure>
                <li>
                    <div><strong><a href="/admin/procedures/${procedure.id}">${procedure.name?html}</a></strong><span>${procedure.category?html} · ${numbers.formatInteger(procedure.price)}원</span></div>
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
            <div class="section-head">
                <h2>최근 상담 신청</h2>
                <a href="/admin/consultations">전체 보기 &rsaquo;</a>
            </div>
            <#if consultations?has_content>
            <ul class="mini-list">
                <#list consultations as item>
                <li>
                    <strong><a href="/admin/consultations/${item.id}">${item.name?html}</a></strong>
                    <span>${item.phone?html} · ${item.area?html} · ${item.preferredContact?html}<#if item.preferredDate??> · 희망일 ${temporals.format(item.preferredDate, 'yyyy.MM.dd')}</#if></span>
                </li>
                </#list>
            </ul>
            <#else><p class="muted">접수된 상담 신청이 없습니다.</p></#if>
        </div>
        <div class="panel">
            <div class="section-head">
                <h2>최근 결제</h2>
                <a href="/admin/payments">전체 보기 &rsaquo;</a>
            </div>
            <#if orders?has_content>
            <ul class="mini-list">
                <#list orders as order>
                <li>
                    <strong><a href="/admin/payments/${order.id}">${order.orderNumber?html}</a></strong>
                    <span>${order.buyer.name?html} · ${order.procedureProduct.name?html} · ${numbers.formatInteger(order.amount)}원 · ${order.pointsUsed}P 사용 · ${fmt.statusLabel(order.status?string)}</span>
                </li>
                </#list>
            </ul>
            <#else><p class="muted">결제 내역이 없습니다.</p></#if>
        </div>
        <div class="panel">
            <div class="section-head">
                <h2>Q&A 답변 관리</h2>
                <a href="/admin/qna">전체 보기 &rsaquo;</a>
            </div>
            <#if qnas?has_content>
            <ul class="mini-list">
                <#list qnas as post>
                <li><a href="/admin/qna/${post.id}">${post.title?html}</a><span>${post.answered?then('답변완료', '대기')}</span></li>
                </#list>
            </ul>
            <#else><p class="muted">등록된 문의가 없습니다.</p></#if>
        </div>
    </section>
</main>
</body>
</html>
