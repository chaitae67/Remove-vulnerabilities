<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Error</title>
</head>
<body>
<h1>Database Error</h1>
<p>There was an unexpected error while processing the database request.</p>
<p><strong>Exception:</strong> <span>${exceptionType}</span></p>
<#if sqlState??>
<p><strong>SQL State:</strong> <span>${sqlState}</span></p>
</#if>
<#if errorCode??>
<p><strong>Error Code:</strong> <span>${errorCode}</span></p>
</#if>
</body>
</html>
