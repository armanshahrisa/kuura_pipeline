/*
#######################################################################################################################################
# This NextFlow script implements a pipeline for the processing of WES & WGS data from raw fastq files through to variant annotation. #
#######################################################################################################################################

This file should be executed in the following manner:

nextflow run dna-seq-pipeline.nf -w <workspaceDir> -profile <configuration.profile>

This will ensure that the parameters specified in <configuration.profile> will be used for the pipelines execution and all the output and working files generated by NextFlow will be placed in the directory specified by <workspaceDir> with their symbolic links placed in the <params.outputDir> directory.
_______________________________________________________________________________________________________________________________________

A Docker image containing the appropriately versioned component tools can be found here: 
_______________________________________________________________________________________________________________________________________

Global I/O parameters are defined in nextflow.config, please edit as appropriate. Key variables are listed here:

- params.dataDir 		- 	Filepath for the pipeline's data source
- params.noThreads		-	The number of threads to be used by processes with parallel execution capability
- params.groupIdentifier	-	Identifier for the dataset/sample group
- params.libraryType		-	Library type
- params.seqPlatform		-	Sequencing platform used to generate the data
- params.allFastq		-	A list of all read fastq files for all samples and replicates
- params.reads			-	A pairwise list of read fastq files
- params.adaptors		-	A pairwise list of adaptor sequences to be removed from reads in readPreProcessing
- params.alignmentReferenceDir	-	The directory containing the reference genome (params.alignmentReference) and relevant index files. Used to parse these files into Docker.
- params.alignmentReference	-	The genome reference fasta to which reads will be aligned in alignToGenome
- params.variantInfoDir		-	The directory containing all variant information files (e.g params.dbSNPcommon). Used to parse these files into Docker.
- params.dbSNPcommon		-	dbSNP's list of common variants for the genome used
- params.outputDir		-	Describes the filepath where symbolic links to the pipeline's processed output are to be placed
- params.container		-	The pipeline's Docker image that contains all the tools necessary for running the pipeline
_______________________________________________________________________________________________________________________________________

*/

// Channel declarations
Channel.fromPath(params.allFastq)
        .ifEmpty { error "Cannot find any fastq files in: ${params.allFastq}" }
        .set { allFastq_ch }
Channel.fromFilePairs(params.reads)
        .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
        .set { readPairs_ch }
Channel.from( "$workflow.launchDir" ).set { runDir_ch } // dont stage run dir for safety reasons, just pass the path

println """\

        =================================================
        |       D N A - S E Q    P I P E L I N E        |
        =================================================

        source data             : ${params.dataDir}
        no. threads             : ${params.noThreads}
        group ID                : ${params.groupIdentifier}
        library type            : ${params.libraryType}
        platform                : ${params.seqPlatform}
        read location           : ${params.dataDir}
        adaptors                : ${params.adaptors}
        genome reference        : ${params.alignmentReference}
        variants for BQSR       : ${params.dbSNPcommon}
        output directory        : ${params.outputDir}


        =================================================
        >               E X E C U T I N G               <
        =================================================
        """
        .stripIndent()


// Execution Level: 1, Input from nextflow.config
// Validates run completion by supplying a process output that will collect output from every other process
process ValidateRunCompletion {

        tag "${runDir}"

        publishDir "${params.outputDir}/"

        input:
        val(runDir) from runDir_ch

        output:
        val('') into doneValidateRunCompletion

        script:
        """
        """
}


// Execution Level: 1, Input from nextflow.config
// Executes FASTQC on all read fastq files
process QualityAssessment {

        label "utuprcagenetics"
	
	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.lightResourceForkThreshold

        tag "FASTQC on $fastq"

        publishDir "$params.outputDir/FASTQC"

        input:
        file(fastq) from allFastq_ch

        output:
        file("${outputZIP}")
        file("${outputHTML}")
	val("DoneInitialFastQC") into doneFastQC        

        script:
        outputZIP = "${fastq}".replaceFirst(/.fastq.gz$/, "_fastqc.zip")
        outputHTML = "${fastq}".replaceFirst(/.fastq.gz$/, "_fastqc.html")

        """
        fastqc -q -o . ${fastq}
        """
}


// Execution Level: 1, Input from nextflow.config
// Runs any preprocessing steps on read fastq files, supplied pairwise. Presently this uses cutadapt and fastp to remove adaptors, filter reads < 70bp (lower limit of BWA-MEM) and of low quality (phred < 20)
process ReadPreProcessing {

        label "utuprcagenetics"
        
	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.lightResourceForkThreshold

        tag "Pre-processing on $sampleID"
        
        publishDir "$params.outputDir/Read_Pre-Processing"

        input:
        set sampleID, file(sampleFastq) from readPairs_ch

        output:
        set val(sampleID), file("${outputFQ1}"), file("${outputFQ2}") into processedReads, processedReads2
        val(sampleID) into doneReadPreProcessing

        script:
        unzippedFQ1 = "${sampleFastq[0]}".replaceFirst(/.gz$/, "")
        unzippedFQ2 = "${sampleFastq[1]}".replaceFirst(/.gz$/, "")
        interimFQ1 = "${sampleID}_R1_interim.fastq"
        interimFQ2 = "${sampleID}_R2_interim.fastq"
        outputFQ1 = "${sampleID}_R1_trimmed.fastq.gz"
        outputFQ2 = "${sampleID}_R2_trimmed.fastq.gz"

        if( params.noAdaptor == 'TRUE' )
        """
        fastp -w ${params.noThreads} -i ${sampleFastq[0]} -I ${sampleFastq[1]} -o $outputFQ1 -O $outputFQ2 -q 15 -l 20 -h fastp_filtering_report.html
        """

        else if (params.noAdaptor == 'FALSE' )
        """
        cutadapt -a ${params.adaptors[0]} -A ${params.adaptors[1]} -m 20 -q 15 -o ${outputFQ1} -p ${outputFQ2} ${sampleFastq}
        """
}


// Execution Level: 1, Input from ReadPreProcessing
// Executes FASTQC on all read fastq files after pre-processing for validation purposes.
process QualityAssessmentProc {

        label "utuprcagenetics"
	
	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.lightResourceForkThreshold

        tag "Post Pre-Processing FASTQC on $sampleID"

        publishDir "$params.outputDir/Post_PreProcess_FASTQC"

        input:
        set sampleID, file(fastq1), file(fastq2) from processedReads

        output:
        file("${outputZIP1}")
        file("${outputZIP2}")
        file("${outputHTML1}")
        file("${outputHTML2}")
        val(sampleID) into donePostPreProcessFastQC

        script:
        outputZIP1 = "${fastq1}".replaceFirst(/.fastq.gz$/, "_fastqc.zip")
        outputZIP2 = "${fastq2}".replaceFirst(/.fastq.gz$/, "_fastqc.zip")
        outputHTML1 = "${fastq1}".replaceFirst(/.fastq.gz$/, "_fastqc.html")
        outputHTML2 = "${fastq2}".replaceFirst(/.fastq.gz$/, "_fastqc.html")

        """
        fastqc -q -o . ${fastq1}
        fastqc -q -o . ${fastq2}
        """
}


// Execution Level: 2, Input from ReadPreProcessing
// Aligns preprocessed reads to the genome using BWA-MEM, then calls Samtools to sort the output into BAM format.
process AlignToGenome {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.heavyResourceForkThreshold
        
        tag "BWI-MEM Alignment on $sampleID"

        publishDir "$params.outputDir/BWI-MEM_Alignment"

        input:
        set sampleID, file(fastq1), file(fastq2) from processedReads2

        output:
        set val(sampleID), file("${outBam}") into bwaAlignment
        val(sampleID) into doneGenomeAlignment

        script:
        outBam = "${sampleID}_BWA_Alignment.bam"
        readGroupInfo = "@RG\\tID:${params.groupIdentifier}\\tSM:${sampleID}\\tPL:${params.seqPlatform}\\tLB:${params.libraryType}"

        """
        bwa mem -v 1 -t ${params.noThreads} -R "$readGroupInfo" ${params.alignmentReference} ${fastq1} ${fastq2} | samtools sort -@${params.noThreads} -o $outBam
        """
}


// Execution Level: 2, Input from AlignToGenome
// Uses picard-tools to mark PCR duplicates.
process MarkDuplicates {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

        tag "Marking Duplicates on $sampleID"

        publishDir "$params.outputDir/DuplicateRemoval"

        input:
        set sampleID, file(alignedBam) from bwaAlignment

        output:
        set val(sampleID), file("${markedDuplicatesBAM}") into noDupBAM
        file("${duplicateSummary}")
        val(sampleID) into doneDuplicateRemoval

        script:
        markedDuplicatesBAM = "${alignedBam}".replaceFirst(/.bam$/, "_duplicates_marked.bam")
        duplicateSummary = "${sampleID}_marked_dup_metrics.txt"

        """
        gatk MarkDuplicates --INPUT ${alignedBam} --OUTPUT $markedDuplicatesBAM --METRICS_FILE $duplicateSummary --VALIDATION_STRINGENCY SILENT
        """
}


// Execution Level: 2, Input from MarkDuplicates
// Applies samtools to sort the BAM files after duplicate removal and also to generate indexes
process SortAndIndexAlignments {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.lightResourceForkThreshold
        
        tag "Sorting and Indexing BAMs for $sampleID"

        publishDir "$params.outputDir/SortedAndIndexedBAMs"

        input:
        set sampleID, file(bamForSorting) from noDupBAM

        output:
        set val(sampleID), file("${sortedBAM}") into sortedAndIndexedBAM // BAI files are used automatically by recalibrateQualityScores which outputs an updated BAI for the BQSR bam
        set val(sampleID), file("${sortedBAM}"), file("${sortedBAMindex}") into sortedAndIndexedBAMforDV // BQSR isn't necessary for DV and can obscure novel variant detection
        val(sampleID) into doneSortAndIndex

        script:
        sortedBAM = "${bamForSorting}".replaceFirst(/_duplicates_marked.bam$/, "_sorted.bam")
        sortedBAMindex = "${bamForSorting}".replaceFirst(/_duplicates_marked.bam$/, "_sorted.bam.bai")
        """
        samtools sort -@${params.noThreads} -o $sortedBAM ${bamForSorting}
        samtools index $sortedBAM
        """
}


// Execution Level: 5, Input from SortAndIndexAlignments
// Applies GATK-BaseRecalibrator to recalibrate the base quality scores
// WARNING: This step is not required by some variant callers (e.g DeepVariant), given that there is a small chance that BQSR can obscure novel variants, it may be best to pass the reads from sortedAndIndexedBAM directly to these callers
process RecalibrateQualityScores {

        label "gatk"
	
	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.heavyResourceForkThreshold
        
        tag "Recalibrating Quality Scores for $sampleID"

        publishDir "$params.outputDir/QualityScoreRecalibration"

        input:
        set sampleID, file(bamForQSR) from sortedAndIndexedBAM

        output:
        set val(sampleID), file("${BQSRbam}") into qualityRecalibratedBAMForGATK
        set val(sampleID), file("${BQSRbam}"), file("${BQSRbai}") into qualityRecalibratedBAMForMosdepth, qualityRecalibratedBAMForStrelka, qualityRecalibratedBAMForFreeBayes, qualityRecalibratedBAMForVarScan
        file("${QSRsummary}")
        val(sampleID) into doneQualityScoreRecalibration

        script:
        QSRsummary = "${sampleID}_Quality_Score_Recalibration.table"
        BQSRbam = "${bamForQSR}".replaceFirst(/_sorted.bam$/, "_Quality_Score_Recalibrated.bam")
        BQSRbai = "${bamForQSR}".replaceFirst(/_sorted.bam$/, "_Quality_Score_Recalibrated.bai")

        """
        gatk BaseRecalibrator -R ${params.alignmentReference} -I ${bamForQSR} --known-sites ${params.dbSNPcommon} --known-sites ${params.millsReference} --known-sites ${params.knownIndels} -O $QSRsummary --use-original-qualities
        gatk ApplyBQSR -R ${params.alignmentReference} -I ${bamForQSR} --bqsr-recal-file $QSRsummary -O $BQSRbam --use-original-qualities
        """
}


// Execution Level: 2, Input from recalibrateQualityScores
// Coverage Analysis with mosdepth on BQSR Alignments
process AnalyseCoverageMosdepth {

        label "mosdepth"
	
	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.heavyResourceForkThreshold
        
        tag "Analysing Coverage with mosdepth for $sampleID"

        publishDir "$params.outputDir/CoverageAnalysis"

        input:
        set sampleID, file(bamForCovAnalysis), file(bamIndex) from qualityRecalibratedBAMForMosdepth

        output:
	set val(sampleID), file("${mosdepthBed}") into mosdepthWEScoverage
        file("${coverageFile}") into mosdepthCoverageFile
        file '*'
        val(sampleID) into doneMosdepthCoverageAnalysis

        script:
	coverageFile = "${sampleID}.mosdepth.global.dist.txt"
	mosdepthFlags = "-n --fast-mode --by 500"
	if( params.libraryType == "WES"){mosdepthFlags="--by ${params.exomeRegionsBed}"}
	mosdepthBed = "${sampleID}.regions.bed.gz"
        if( params.libraryType == "WES"){mosdepthBed = "${sampleID}.per-base.bed.gz"}

        """
	mosdepth -t ${params.noThreads} ${mosdepthFlags} ./${sampleID} ${bamForCovAnalysis}
	"""
}


// Execution Level: 2, Input from analyseCoverageMosdepth
// Extra processing steps for WES coverage to restrict the depth figures to exonic regions
process AnalyseCoverageMosdepthWES {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold
        
        tag "Analysing Coverage with mosdepth for $sampleID - additional WES specific analysis"

	publishDir "$params.outputDir/CoverageAnalysis"

	when:
	params.libraryType == "WES"

	input:
	set val(sampleID), file(coverageBed) from mosdepthWEScoverage	

	output:
	file("${exomeCoverage}")

	script:
	exomeCoverage = "${sampleID}_exome_coverage.bed"

	"""
	bedtools intersect -a ${coverageBed} -b ${params.exomeRegionsBed} > $exomeCoverage
        """
}


// Execution Level: 2, Input from analyseCoverageMosdepth
// Plotting Coverage Analysis with mosdepth over all samples
process plotCoverageMosdepth {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

        tag "Plotting Coverage with mosdepth for $sampleID"

        publishDir "$params.outputDir/CoverageAnalysis"

        input:
        file(coverageResFiles) from mosdepthCoverageFile.collect()

        output:
        file('*')

        script:
	"""
	python /tools/mosdepth/scripts/plot-dist.py -o coverage_plot.html ${coverageResFiles}
        """
}


// Execution Level: 3, Input from QualityScoreRecalibration
// Uses GATK HaplotypeCaller to call variants from the BSQR BAM files
process CallVariantsGATK {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

	tag "Variant calling using GATK HaplotypeCaller for $sampleID"

	publishDir "$params.outputDir/VariantsFromGATK"
        
        input:
	set sampleID, file(BQSRbam) from qualityRecalibratedBAMForGATK

        output:
	set val(sampleID), file("${gatk_hc}"), file("${gatk_hc_tbi}") into gatk_vcf
	val(sampleID) into doneVariantCallingGATK

        script:
	gatk_hc = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_haplotypeCaller.vcf.gz")
	gatk_hc_tbi = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/, "_haplotypeCaller.vcf.gz.tbi")

        """
	gatk HaplotypeCaller -R ${params.alignmentReference} -I ${BQSRbam} -stand-call-conf 30.0 --dbsnp ${params.dbSNPReference} -O $gatk_hc
        """
}


// Execution Level : 3, Input from callVariantsGATK
// Using VariantRecalibrator to build the SNP recalibration model
process VariantRecalibration {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold 

	tag "Variant recalibration using GATK VariantRecalibrator for $sampleID"

	publishDir "$params.outputDir/recalibratedVariants"

        input:
	set sampleID, file(gatk_hc), file(gatk_hc_tbi) from gatk_vcf

        output:
	set val(sampleID), file("${gatkHC_vc}"), file("${gatk_recal_idx}"), file("${tranches_file}"), file("${gatk_hc}"), file("${gatk_hc_tbi}") into gatk_recal_files
	file '*'
	val(sampleID) into doneVariantRecalibration

	script:
	gatkHC_vc = "${gatk_hc}".replaceFirst(/_haplotypeCaller.vcf.gz$/, "_haplotypeCaller_recalibrate_SNP.recal")
	tranches_file = "${sampleID}_recalibrate_SNP.tranches"
	rscript_file = "${sampleID}_recalibrate_SNP_plots.R"
	gatk_recal_idx = "${gatkHC_vc}".replaceFirst(/_haplotypeCaller_recalibrate_SNP.recal$/, "_haplotypeCaller_recalibrate_SNP.recal.idx")

	"""
	gatk VariantRecalibrator -R ${params.alignmentReference} -V ${gatk_hc} --resource:hapmap,known=false,training=true,truth=true,prior=15 ${params.hapmapReference} --resource:omni,known=false,training=true,truth=true,prior=12 ${params.omniReference} --resource:1000G,known=false,training=true,truth=true,prior=10 ${params.reference1000G} --resource:dbsnp,known=false,training=true,truth=true,prior=7 ${params.dbSNPReference} -an DP -an QD -an FS -an MQRankSum -an ReadPosRankSum -mode SNP -O $gatkHC_vc --tranches-file ${tranches_file} --max-gaussians 4 --rscript-file ${rscript_file}
        gatk IndexFeatureFile -I ${gatkHC_vc} -O $gatk_recal_idx
	"""
}


// Execution Level : 3, Input from variantRecalibration
// Uses ApplyVQSR to apply the desired level of recalibration to the SNPs in the callset
process ApplyRecalibration {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

	tag "Applying desired level of recalibration using GATK ApplyVQSR for $sampleID"

	publishDir "$params.outputDir/recalibratedVariants"

        input:
	set val(sampleID), file(gatkHC_vc), file(gatk_recal_idx), file(tranches_file), file(gatk_hc), file(gatk_hc_tbi) from gatk_recal_files
        
        output:
	set val(sampleID), file(gatk_hc_recalibratedVCF) into gatk_recalibratedVariants
	val(sampleID) into doneApplyingVariantRecalibration

        script:
	gatk_hc_recalibratedVCF = "${gatkHC_vc}".replaceFirst(/_haplotypeCaller_recalibrate_SNP.recal$/, "_haplotypeCaller_recalibrated_snps.vcf")

        """
	gatk ApplyVQSR -R ${params.alignmentReference} -V ${gatk_hc} -mode SNP --recal-file ${gatkHC_vc} --tranches-file ${tranches_file} -O $gatk_hc_recalibratedVCF
        """
}


// Execution Level : 3, Input from applyRecalibration
// Recalibrating variant quality scores for Indels
process IndelRecalibration {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

	tag "Indel recalibration using GATK VariantRecalibrator for $sampleID"

	publishDir "$params.outputDir/recalibratedIndels"

        input:
	set val(sampleID), file(gatk_hc_recalibratedVCF) from gatk_recalibratedVariants

        output:
	set val(sampleID), file("${gatk_indel_recal}"), file("${gatk_indel_recal_idx}"), file("${tranches_file_indels}"), file ("${gatk_hc_recalibratedVCF}") into indel_recal_files
	file '*'
	val(sampleID) into doneIndelRecalibration 

        script:
	gatk_indel_recal = "${gatk_hc_recalibratedVCF}".replaceFirst(/_haplotypeCaller_recalibrated_snps.vcf$/, "_haplotypeCaller_recalibrate_SNP_INDELs.recal")
	gatk_indel_recal_idx = "${gatk_indel_recal}".replaceFirst(/_haplotypeCaller_recalibrate_SNP_INDELs.recal$/, "_haplotypeCaller_recalibrate_SNP_INDELs.recal.idx")
	tranches_file_indels = "${sampleID}_recalibrate_SNP_INDELs.tranches"
	rscript_file_indels = "${sampleID}_recalibrate_SNP_INDELs.plots.R"

        
        """
	gatk VariantRecalibrator -R ${params.alignmentReference} -V ${gatk_hc_recalibratedVCF} --resource:knownIndels,known=true,training=false,truth=false,prior=2 ${params.knownIndels} --resource:mills,known=false,training=true,truth=true,prior=12 ${params.millsReference} -an DP -an QD -an FS -an MQRankSum -an ReadPosRankSum -mode INDEL -O ${gatk_indel_recal} --tranches-file ${tranches_file_indels} --max-gaussians 4 --rscript-file ${rscript_file_indels}
        gatk IndexFeatureFile -I ${gatk_indel_recal} -O $gatk_indel_recal_idx
        """
} 


// Execution Level : 3, Input from IndelRecalibration
// Uses ApplyVQSR to apply the desired level of recalibration to the INDELs in the callset
process ApplyIndelRecalibration {

        label "gatk"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

	tag "Applying desired level of recalibration for Indels using GATK ApplyVQSR for $sampleID"

	publishDir "$params.outputDir/recalibratedIndels"

        input:
	set val(sampleID), file(gatk_indel_recal), file(gatk_indel_recal_idx), file(tranches_file_indels), file(gatk_hc_recalibratedVCF) from indel_recal_files

        output:
	set val(sampleID), file("${gatk_hc_snp_indel_recalibratedVCF_gz}"), file("${gatk_hc_snp_indel_recalibratedVCF_gz_tbi}") into gatk_recalibratedIndels
	val(sampleID) into doneApplyingIndelRecalibration

        script:
	gatk_hc_snp_indel_recalibratedVCF = "${gatk_indel_recal}".replaceFirst(/_haplotypeCaller_recalibrate_SNP_INDELs.recal$/,"_haplotypeCaller_recalibrated_SNPs_INDELs.vcf")
        gatk_hc_snp_indel_recalibratedVCF_gz = "${gatk_indel_recal}".replaceFirst(/_haplotypeCaller_recalibrate_SNP_INDELs.recal$/,"_haplotypeCaller_recalibrated_SNPs_INDELs.vcf.gz")
        gatk_hc_snp_indel_recalibratedVCF_gz_tbi = "${gatk_indel_recal}".replaceFirst(/_haplotypeCaller_recalibrate_SNP_INDELs.recal$/,"_haplotypeCaller_recalibrated_SNPs_INDELs.vcf.gz.tbi")
        """
	gatk ApplyVQSR -R ${params.alignmentReference} -V ${gatk_hc_recalibratedVCF} -mode INDEL --recal-file ${gatk_indel_recal} --tranches-file ${tranches_file_indels} -O ${gatk_hc_snp_indel_recalibratedVCF} \
        && bgzip -c ${gatk_hc_snp_indel_recalibratedVCF} > ${gatk_hc_snp_indel_recalibratedVCF_gz} \
        && tabix -p vcf ${gatk_hc_snp_indel_recalibratedVCF_gz}
        """
}


// Execution Level: 3, Input from SortAndIndexAlignments
// Uses Deep Variant to call variants from Sorted and Indexed BAM files
process CallVariantsDV {

        label "deepvariant"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold

	tag "Variant calling deepvariant for $sampleID"

	publishDir "$params.outputDir/VariantsFromDV"
	
        input:
        set sampleID, file(sortedBAM), file(sortedBAMindex) from sortedAndIndexedBAMforDV

        output:
	set val(sampleID), file("${outFile1}"), file("${outFile1_index}")  into dv_variants
        file '*'
	val(sampleID) into doneVariantCallingDV

        script:
	outFile1 = "${sampleID}.DV.vcf.gz"
	outFile1_index = "${sampleID}.DV.vcf.gz.tbi"
        outFile2 = "${sampleID}.DV.g.vcf.gz"
	outFile2_index = "${sampleID}.DV.g.vcf.gz.tbi"

	"""
        /opt/deepvariant/bin/run_deepvariant --model_type=${params.libraryType} --ref=${params.alignmentReference} --reads=${sortedBAM} --output_vcf=${outFile1} --output_gvcf=${outFile2} --intermediate_results_dir "$sampleID"_deep_variant --num_shards=$shards
        """
}


// Execution Level: 3, Input from QualityScoreRecalibration
// Uses Strelka to call variants from the BSQR BAM files
process CallVariantsStrelka {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

        maxForks params.heavyResourceForkThreshold

	tag "Variant calling using Strelka for $sampleID"

	publishDir "$params.outputDir/VariantsFromStrelka"
        
        input:
	set sampleID, file(BQSRbam), file(BQSRbai) from qualityRecalibratedBAMForStrelka

        output:
	//set val(sampleID), file("*variants.vcf.gz"), file("*variants.vcf.gz.tbi") into strelka_vcf_out
        set val(sampleID), file("${strelka_variants}"), file("${strelka_variants_index}") into strelka_vcf_out
        file '*'
	val(sampleID) into doneVariantCallingStrelka

        script:
        strelka_genome = "${sampleID}_genome.vcf.gz"
        strelka_genome_index = "${sampleID}_genome.vcf.gz.tbi"
        strelka_variants = "${sampleID}_variants.vcf.gz"
        strelka_variants_index = "${sampleID}_variants.vcf.gz.tbi"
        """
	configureStrelkaGermlineWorkflow.py --bam ${BQSRbam} --referenceFasta ${params.alignmentReference} --runDir "$sampleID"_strelka && "$sampleID"_strelka/runWorkflow.py -m local -j 4 \
        && mv "$sampleID"_strelka/results/variants/genome.*.vcf.gz ${strelka_genome} \
        && mv "$sampleID"_strelka/results/variants/genome.*.vcf.gz.tbi ${strelka_genome_index} \
        && mv "$sampleID"_strelka/results/variants/variants.vcf.gz ${strelka_variants} \
        && mv "$sampleID"_strelka/results/variants/variants.vcf.gz.tbi ${strelka_variants_index}
        """
}


// Execution Level: 3, Input from QualityScoreRecalibration
// Uses Freebayes to call variants from the BSQR BAM files
process CallVariantsFreebayes {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.lightResourceForkThreshold
        
        tag "Variant calling using Freebayes for $sampleID"

	publishDir "$params.outputDir/VariantsFromFreebayes"
        
        input:
        set sampleID, file(BQSRbam), file(BQSRbai) from qualityRecalibratedBAMForFreeBayes

        output:
	set val(sampleID), file("${freebayes_vcf_gz}"), file("${freebayes_vcf_gz_tbi}") into freebayes_vcf_out
	val(sampleID) into doneVariantCallingFreebayes

        script:
	freebayes_vcf = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_Freebayes.vcf")
        freebayes_vcf_gz = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_Freebayes.vcf.gz")
        freebayes_vcf_gz_tbi = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_Freebayes.vcf.gz.tbi")
        """
	freebayes -f ${params.alignmentReference} ${BQSRbam} > ${freebayes_vcf} \
        && bgzip -c ${freebayes_vcf} > ${freebayes_vcf_gz} \
        && tabix -p vcf ${freebayes_vcf_gz}
        """
}


// Execution Level: 3, Input from QualityScoreRecalibration
// Uses VarScan to call variants from the BSQR BAM files
process CallVariantsVarScan {

        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.lightResourceForkThreshold
        
        tag "Variant calling using VarScan for $sampleID"

	publishDir "$params.outputDir/VariantsFromVarScan"
        
        input:
        set sampleID, file(BQSRbam), file(BQSRbai) from qualityRecalibratedBAMForVarScan

        output:
	set val(sampleID), file("${varscan_vcf_gz}"), file("${varscan_vcf_gz_tbi}") into varscan_vcf_out
        file '*'
	val(sampleID) into doneVariantCallingVarScan

        script:
	varscan_vcf = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_VarScan.vcf")
        varscan_vcf_gz = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_VarScan.vcf.gz")
        varscan_vcf_gz_tbi = "${BQSRbam}".replaceFirst(/_Quality_Score_Recalibrated.bam$/,"_VarScan.vcf.gz.tbi")

        """
        samtools mpileup -f ${params.alignmentReference} ${BQSRbam} | java -jar /tools/varscan-2.4.2/VarScan.jar mpileup2snp --output-vcf 1 > ${varscan_vcf} \
        && bgzip -c ${varscan_vcf} > ${varscan_vcf_gz} \
        && tabix -p vcf ${varscan_vcf_gz}
        """
}


// Execution Level: 4, Input from ApplyIndelRecalibration, CallVariantsDV, CallVariantsStrelka, CallVariantsFreebayes, CallVariantsVarScan
// Uses bcftools isec to calculate consensus and generate input for VEP
process FormatForConsensus {
        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.lightResourceForkThreshold
        
        tag "Calculating consensus for $sampleID"

        publishDir "$params.outputDir/VariantConsensus"
        
        input:
        set val(sampleID), file(gatk_hc_snp_indel_recalibratedVCF_gz), file(gatk_hc_snp_indel_recalibratedVCF_gz_tbi), file(outFile1), file(outFile1_index), file(strelka_variants), file(strelka_variants_index), file(freebayes_vcf_gz), file(freebayes_vcf_gz_tbi), file(varscan_vcf_gz), file(varscan_vcf_gz_tbi) from gatk_recalibratedIndels.join(dv_variants).join(strelka_vcf_out).join(freebayes_vcf_out).join(varscan_vcf_out)

        output:
        set val(sampleID), file("${vep_input}") into consensusVariantCall
        file '*'
        val(sampleID) into doneVariantConsensus
        
        script:
        gatk_lowConf = "${sampleID}_gatk_lowConf.vcf"
        deepvariant_lowconf = "${sampleID}_deepvariant_lowConf.vcf"
        strelka_lowConf = "${sampleID}_strelka_lowConf.vcf"
        freebayes_lowConf = "${sampleID}_freebayes_lowConf.vcf"
        varscan_lowConf = "${sampleID}_varscan_lowConf.vcf"
        consensus = "${sampleID}_variantConsensus_highConf.txt"
        readme = "${sampleID}_README.txt"
        vep_input = "${sampleID}_variantConsensus_highConf_VEPInput.txt"
        """
        bcftools isec -n=5 ${gatk_hc_snp_indel_recalibratedVCF_gz} ${outFile1} ${strelka_variants} ${freebayes_vcf_gz} ${varscan_vcf_gz} -p "$sampleID"_consensus/ \
        && mv "$sampleID"_consensus/0000.vcf ${gatk_lowConf} \
        && mv "$sampleID"_consensus/0001.vcf ${deepvariant_lowconf} \
        && mv "$sampleID"_consensus/0002.vcf ${strelka_lowConf} \
        && mv "$sampleID"_consensus/0003.vcf ${freebayes_lowConf} \
        && mv "$sampleID"_consensus/0004.vcf ${varscan_lowConf} \
        && mv "$sampleID"_consensus/README.txt ${readme} \
        && mv "$sampleID"_consensus/sites.txt ${consensus} \
        && awk 'BEGIN{FS=OFS="\t"} { \$(NF+1) = "." ; print }' ${consensus} | awk 'BEGIN{FS=OFS="\t"} {print \$1,\$2,\$6,\$3,\$4}' > ${vep_input}
        """
}


// Execution Level: 4, Input from FormatForConsensus
// Uses VEP to annotate consensus variants
process variantEffectPredictionConsensus {

        label "vep"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.heavyResourceForkThreshold 

	tag "Running ensembl variant effect predictor on consensus for $sampleID"
 
	publishDir "$params.outputDir/Variant_effect_predictor"
 
        input:
	set val(sampleID), file(vep_input) from consensusVariantCall

        output:
	file '*'
	val(sampleID) into doneEffectPrediction

        script:
	vep_ann_consensus = "${vep_input}".replaceFirst(/_VEPInput.txt$/, "_VEP.ann.vcf")
        // --plugin CADD,${params.CADDsnvs},${params.CADDindels} --plugin REVEL,${params.REVEL}
        """
	vep --fork ${params.noThreads} --offline --host ensembldb.ensembl.org --buffer_size 100000 --check_existing --everything --allele_number --total_length --humdiv --no_progress --cache --dir_cache ${params.vepCache} --species homo_sapiens --assembly GRCh38 --input_file ${vep_input} --output_file $vep_ann_consensus --force_overwrite --vcf --host ensembldb.ensembl.org 
        """
}


doneValidateRunCompletion.concat(
        doneFastQC,
	doneReadPreProcessing,
	donePostPreProcessFastQC,
	doneGenomeAlignment,
	doneDuplicateRemoval,
	doneSortAndIndex,
	doneQualityScoreRecalibration,
        doneMosdepthCoverageAnalysis,
        doneVariantCallingGATK,
        doneVariantRecalibration,
        doneApplyingVariantRecalibration,
        doneIndelRecalibration,
        doneApplyingIndelRecalibration,
        doneVariantCallingDV,
        doneVariantCallingStrelka,
        doneVariantCallingFreebayes,
        doneVariantCallingVarScan,
	doneVariantConsensus,
        doneEffectPrediction
        ).tap { allDone }

// Execution Level: Final
// Uses MultiQC to generate summaries of the run.
process multiqc {
        label "utuprcagenetics"

	scratch '/mount/persistant_volume_11tb/pipeline_test/nxf_tmp/'

	maxForks params.lightResourceForkThreshold
        
        tag "Generating MultiQC Report"

	publishDir "${params.outputDir}/MultiQC_Report", mode: 'copy'

	input:
	val(allVals) from allDone.collect()
	file(outDir) from Channel.fromPath("${params.outputDir}")

	output:
	file "multiqc_report.html"
	file "multiqc_data"

	script:
	"""
	multiqc "${outDir}"
	"""
}
