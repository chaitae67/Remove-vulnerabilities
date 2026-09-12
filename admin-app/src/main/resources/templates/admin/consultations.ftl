<#assign navActive = "consultations">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>상담 신청 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">CONSULTATIONS</p>
            <h1>상담 신청 관리</h1>
            <p>신청 내역을 클릭하면 상세 화면에서 날짜·회원 정보를 수정하거나 삭제할 수 있습니다.</p>
        </div>
        <form class="admin-search" action="/admin/consultations" method="get">
            <input name="keyword" type="search" placeholder="이름 · 연락처 · 관심 부위" value="${(keyword!'')?html}">
            <button class="button button-small" type="submit">검색</button>
        </form>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>신청 목록</h2>
            <span class="muted">${consultations?size}건<#if keyword?has_content> · '${keyword?html}' 검색 결과</#if></span>
        </div>
        <#if consultations?has_content>
        <div class="admin-table-wrap">
            <table class="admin-table">
                <thead>
                <tr>
                    <th scope="col">신청자</th>
                    <th scope="col">연락처</th>
                    <th scope="col">관심 부위</th>
                    <th scope="col">희망일</th>
                    <th scope="col">특이사항</th>
                    <th scope="col">신청일</th>
                    <th scope="col"><span class="sr-only">상세</span></th>
                </tr>
                </thead>
                <tbody>
                <#list consultations as item>
                <tr data-href="/admin/consultations/${item.id}">
                    <td><a class="cell-link" href="/admin/consultations/${item.id}">${item.name?html}</a></td>
                    <td>${item.phone?html}</td>
                    <td>${item.area?html}<small class="muted"> · ${item.preferredContact?html}</small></td>
                    <td><#if item.preferredDate??><time>${temporals.format(item.preferredDate, 'yyyy.MM.dd')}</time><#else><span class="muted">-</span></#if></td>
                    <td><#if item.adminNote?has_content><span class="state">메모</span><#else><span class="muted">-</span></#if></td>
                    <td><time>${temporals.format(item.createdAt, 'yyyy.MM.dd HH:mm')}</time></td>
                    <td class="cell-action"><a href="/admin/consultations/${item.id}">상세 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>표시할 상담 신청이 없습니다.</strong>
            <p><#if keyword?has_content>검색 조건을 바꿔 다시 시도해 보세요.<#else>고객이 상담을 신청하면 이곳에 표시됩니다.</#if></p>
        </div>
        </#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
</body>
</html>
