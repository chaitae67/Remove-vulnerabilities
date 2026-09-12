<#assign navActive = "procedures">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>시술 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title">
        <p class="eyebrow">PROCEDURES</p>
        <h1>시술 관리</h1>
        <p>시술을 클릭하면 가격과 설명을 수정하거나 판매 여부를 바꿀 수 있습니다.</p>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>시술/상담 패키지</h2>
            <span class="muted">${procedures?size}건</span>
        </div>
        <#if procedures?has_content>
        <div class="admin-table-wrap">
            <table class="admin-table">
                <thead>
                <tr>
                    <th scope="col">시술명</th>
                    <th scope="col">분류</th>
                    <th scope="col">가격</th>
                    <th scope="col">판매 상태</th>
                    <th scope="col">요약</th>
                    <th scope="col"><span class="sr-only">상세</span></th>
                </tr>
                </thead>
                <tbody>
                <#list procedures as procedure>
                <tr data-href="/admin/procedures/${procedure.id}">
                    <td><a class="cell-link" href="/admin/procedures/${procedure.id}">${procedure.name?html}</a></td>
                    <td>${procedure.category?html}</td>
                    <td><strong>${numbers.formatInteger(procedure.price)}원</strong></td>
                    <td><span class="state <#if procedure.active>status-paid<#else>status-canceled</#if>">${procedure.active?then('판매중', '중지')}</span></td>
                    <td class="cell-ellipsis">${procedure.summary?html}</td>
                    <td class="cell-action"><a href="/admin/procedures/${procedure.id}">상세 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>등록된 시술/상담 패키지가 없습니다.</strong>
            <p>대시보드의 XML 일괄 등록으로 상품을 추가할 수 있습니다.</p>
        </div>
        </#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
</body>
</html>
