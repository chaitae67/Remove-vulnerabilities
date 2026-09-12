<#assign navActive = "records">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>의무기록 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title">
        <p class="eyebrow">RECORDS</p>
        <h1>의무기록 / 동의서 관리</h1>
        <p>환자별 진료 기록과 수술 동의서 파일을 내려받을 수 있습니다.</p>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>보관 문서</h2>
            <span class="muted">${files?size}건</span>
        </div>
        <#if files?has_content>
        <div class="admin-table-wrap">
            <table class="admin-table">
                <thead>
                <tr>
                    <th scope="col">파일명</th>
                    <th scope="col"><span class="sr-only">다운로드</span></th>
                </tr>
                </thead>
                <tbody>
                <#list files as file>
                <tr>
                    <td>${file?html}</td>
                    <td class="cell-action"><a href="/admin/records/download?file=${file?url}">다운로드 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>보관된 문서가 없습니다.</strong>
            <p>진료 기록과 동의서가 등록되면 이곳에 표시됩니다.</p>
        </div>
        </#if>
    </section>
</main>
</body>
</html>
